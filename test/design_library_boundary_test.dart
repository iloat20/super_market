/// 设计库边界守门：全仓库只许用 `package:material_ui/material_ui.dart`。
///
/// ## 为什么需要这么一条测试
///
/// 2026-11-07 把 42 处 `package:flutter/material.dart` 换成了 `material_ui`
/// （README 二·四十三）。旧库在 3.47 里**仍然能通过 analyze**，所以回退是
/// 无声的：IDE 自动补全默认给的就是旧库，随手一个 import 就会把两套 Material
/// 同时拉进包里——类型不互通（`ThemeData` / `Widget` 之外全是两个类），
/// 而 `flutter analyze` 只会报在你真正跨库传值的那一行，甚至不报。
///
/// 这条测试把「无声回退」变成「当场变红」：只要 `lib/` / `test/` / `tool/` 里
/// 再出现旧库 import，它立刻红，并指名是哪个文件。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 旧设计库的 import 前缀——出现即违规。
const List<String> _legacyLibraries = <String>[
  "import 'package:flutter/material.dart'",
  "import 'package:flutter/cupertino.dart'",
];

/// 递归扫描 [root] 下所有 `.dart`，返回引用了旧设计库的**相对路径**（升序）。
///
/// 只做前缀匹配、不做语法解析：这里要挡的是「有没有这个 import」，
/// 不是「代码正确不正确」——analyze 管后者。
List<String> findLegacyDesignImports(Directory root) {
  if (!root.existsSync()) {
    return <String>[];
  }
  final List<String> hits = <String>[];
  for (final FileSystemEntity entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) {
      continue;
    }
    final List<String> lines = entity.readAsLinesSync();
    for (final String line in lines) {
      if (_legacyLibraries.any(line.trimLeft().startsWith)) {
        // 统一成正斜杠：Windows 上 path 是 `nested\b.dart`，报错信息里的
        // 分隔符混着两种会让「照抄路径去改」变成一件麻烦事。
        hits.add(
          entity.path.substring(root.path.length + 1).replaceAll(r'\', '/'),
        );
        break;
      }
    }
  }
  hits.sort();
  return hits;
}

void main() {
  test('仓库里不允许出现旧设计库 import（material / cupertino）', () {
    // 三个目录都要扫：test 里的 widget 一旦用旧库，会在测试进程里
    // 同时装载两套 Material，断言照样绿、真机行为却不一样。
    final Map<String, List<String>> hits = <String, List<String>>{
      'lib': findLegacyDesignImports(Directory('lib')),
      'test': findLegacyDesignImports(Directory('test')),
      'tool': findLegacyDesignImports(Directory('tool')),
    };
    final List<String> offenders = <String>[
      for (final MapEntry<String, List<String>> e in hits.entries)
        for (final String path in e.value) '${e.key}/$path',
    ];
    expect(
      offenders,
      isEmpty,
      reason: '又用回 package:flutter/material.dart 了。全库统一走 '
          'package:material_ui/material_ui.dart（README 二·四十三）。',
    );
  });

  test('扫描器不是摆设：合成目录里两行旧 import 必须被点名', () {
    final Directory tmp = Directory.systemTemp.createTempSync('design_boundary_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File('${tmp.path}/a.dart').writeAsStringSync(
      "import 'package:flutter/material.dart';\n",
    );
    File('${tmp.path}/nested/b.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        "import 'dart:io';\n"
        "import 'package:flutter/cupertino.dart';\n",
      );
    File('${tmp.path}/ok.dart').writeAsStringSync(
      "import 'package:material_ui/material_ui.dart';\n",
    );
    // 缩进过的 import（写在别处被误拷）同样要抓到
    File('${tmp.path}/indented.dart').writeAsStringSync(
      "  import 'package:flutter/material.dart';\n",
    );

    expect(
      findLegacyDesignImports(tmp),
      <String>['a.dart', 'indented.dart', 'nested/b.dart'],
      reason: 'material / cupertino / 缩进三种形态都要命中，新库不能误报',
    );
  });

  test('pubspec 直接声明 material_ui（不是靠传递依赖捡来的）', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
      pubspec.contains(RegExp(r'^\s{2}material_ui:', multiLine: true)),
      isTrue,
      reason: '直接 import 的包必须直接依赖，否则 depend_on_referenced_packages '
          '会在下一次 analyze 时报；而且有人删掉它时没人发现。',
    );
  });

  test('迁移面没有缩水：至少 20 个文件在用新库', () {
    int count = 0;
    for (final Directory dir in <Directory>[
      Directory('lib'),
      Directory('test'),
    ]) {
      for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
        if (entity is File &&
            entity.path.endsWith('.dart') &&
            entity.readAsStringSync().contains("import 'package:material_ui/")) {
          count++;
        }
      }
    }
    expect(
      count,
      greaterThanOrEqualTo(20),
      reason: '迁移时是 42 个文件。数量骤降说明有人把 import 改回去了，'
          '或者守门测试自己被改松了。',
    );
  });
}
