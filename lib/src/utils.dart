// Copyright 2017 Workiva Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:io';

import 'package:glob/glob.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'constants.dart';

/// Logger instance to use within dependency_validator.
final Logger logger = Logger('dependency_validator');

/// Returns a multi-line string with all [items] in a bulleted list format.
String bulletItems(Iterable<String> items) => items.map((l) => '  * $l').join('\n');

/// Returns the name of the package referenced in the `include:` directive in an
/// analysis_options.yaml file, or null if there is not one.
String getAnalysisOptionsIncludePackage({String path}) {
  final optionsFile = File(p.join(path ?? p.current, 'analysis_options.yaml'));
  if (!optionsFile.existsSync()) return null;

  final YamlMap analysisOptions = loadYaml(optionsFile.readAsStringSync());
  if (analysisOptions == null) return null;

  final String include = analysisOptions['include'];
  if (include == null || !include.startsWith('package:')) return null;

  return Uri.parse(include).pathSegments.first;
}

/// Returns an iterable of all Dart files (files ending in .dart) in the given
/// [dirPath] excluding any files matched by any glob in [excludes].
///
/// This also excludes Dart files that are in a hidden directory, like
/// `.dart_tool`.
Iterable<File> listDartFilesIn(String dirPath, List<Glob> excludes) =>
    listFilesWithExtensionIn(dirPath, excludes, 'dart');

/// Returns an iterable of all Scss files (files ending in .scss) in the given
/// [dirPath] excluding any files matched by any glob in [excludes].
///
/// This also excludes Dart files that are in a hidden directory, like
/// `.dart_tool`.
Iterable<File> listScssFilesIn(String dirPath, List<Glob> excludes) =>
    listFilesWithExtensionIn(dirPath, excludes, 'scss');

/// Returns an iterable of all Less files (files ending in .less) in the given
/// [dirPath] excluding any sub-directories specified in [excludedDirs].
///
/// This also excludes Less files that are in a `packages/` subdirectory.
Iterable<File> listLessFilesIn(String dirPath, List<Glob> excludedDirs) =>
    listFilesWithExtensionIn(dirPath, excludedDirs, 'less');

/// Returns an iterable of all files ending in .[extension] in the given
/// [dirPath] excluding any files matched by any glob in [excludes].
///
/// This also excludes Dart files that are in a hidden directory, like
/// `.dart_tool`.
Iterable<File> listFilesWithExtensionIn(String dirPath, List<Glob> excludes, String ext) {
  if (!FileSystemEntity.isDirectorySync(dirPath)) return [];

  return Directory(dirPath)
      .listSync(recursive: true)
      .whereType<File>()
      // Skip files in hidden directories (e.g. `.dart_tool/`)
      .where((file) => !p.split(file.path).any((d) => d != '.' && d.startsWith('.')))
      // Filter by the given file extension
      .where((file) => p.extension(file.path) == '.$ext')
      // Skip any files that match one of the given exclude globs
      .where((file) => excludes.every((glob) => !glob.matches(file.path)));
}

/// Logs a warning with the given [infraction] and lists all of the given
/// [dependencies] under that infraction.
void logDependencyInfractions(String infraction, Iterable<String> dependencies) {
  final sortedDependencies = dependencies.toList()..sort();
  logger.warning([infraction, bulletItems(sortedDependencies), ''].join('\n'));
}

/// Logs a info with the given [info] and lists all of the given
/// [dependencies] under that.
void logDependencyInfo(String info, Iterable<String> dependencies) {
  final sortedDependencies = dependencies.toList()..sort();
  logger.info([info, bulletItems(sortedDependencies), ''].join('\n'));
}

/// Lists the packages with infractions
List<String> getDependenciesWithPins(Map dependencies, {List<String> ignoredPackages = const []}) {
  final List<String> infractions = [];
  for (String packageName in dependencies.keys) {
    if (ignoredPackages.contains(packageName)) {
      continue;
    }

    String version;
    final packageMeta = dependencies[packageName];

    if (packageMeta is String) {
      version = packageMeta;
    } else if (packageMeta is Map) {
      if (packageMeta.containsKey('version')) {
        version = packageMeta['version'];
      } else {
        // This feature only works for versions, not git refs or paths.
        continue;
      }
    } else {
      continue; // no version string set
    }

    final DependencyPinEvaluation evaluation = inspectVersionForPins(version);

    if (evaluation.isPin) {
      infractions.add('$packageName: $version -- ${evaluation.message}');
    }
  }

  return infractions;
}

/// Returns the reason a version is a pin or null if it's not.
DependencyPinEvaluation inspectVersionForPins(String version) {
  final VersionConstraint constraint = VersionConstraint.parse(version);

  if (constraint.isAny) {
    return DependencyPinEvaluation.notAPin;
  }

  if (constraint is Version) {
    return DependencyPinEvaluation.directPin;
  }

  if (constraint is VersionRange) {
    if (constraint.includeMax) {
      return DependencyPinEvaluation.inclusiveMax;
    }

    final Version max = constraint.max;

    if (max == null) {
      return DependencyPinEvaluation.notAPin;
    }

    if (max.build.isNotEmpty || (max.isPreRelease && !max.isFirstPreRelease)) {
      return DependencyPinEvaluation.buildOrPrerelease;
    }

    if (max.major > 0) {
      if (max.patch > 0) {
        return DependencyPinEvaluation.blocksPatchReleases;
      }

      if (max.minor > 0) {
        return DependencyPinEvaluation.blocksMinorBumps;
      }
    } else {
      if (max.patch > 0) {
        return DependencyPinEvaluation.blocksMinorBumps;
      }
    }

    return DependencyPinEvaluation.notAPin;
  }

  return DependencyPinEvaluation.emptyPin;
}
