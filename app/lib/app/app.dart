import 'package:flutter/material.dart';

/// 应用根组件。路由、主题和后端服务的注入以后在这里接入。
class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '日常记账',
      theme: ThemeData(brightness: Brightness.light),
      darkTheme: ThemeData(brightness: Brightness.dark),
      home: const Scaffold(
        body: Center(child: Text('项目骨架')),
      ),
    );
  }
}
