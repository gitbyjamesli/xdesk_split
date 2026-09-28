import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/dialog.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/desktop/pages/file_manager_page.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:get/get.dart';

import '../../models/platform_model.dart';

/// File Transfer for multi tabs
class FileManagerTabPage extends StatefulWidget {
  final Map<String, dynamic> params;

  const FileManagerTabPage({Key? key, required this.params}) : super(key: key);

  @override
  State<FileManagerTabPage> createState() => _FileManagerTabPageState(params);
}

class _FileManagerTabPageState extends State<FileManagerTabPage> {
  DesktopTabController get tabController => Get.find<DesktopTabController>();

  static const IconData selectedIcon = Icons.file_copy_sharp;
  static const IconData unselectedIcon = Icons.file_copy_outlined;

  _FileManagerTabPageState(Map<String, dynamic> params) {
    Get.put(DesktopTabController(tabType: DesktopTabType.fileTransfer));
    tabController.onSelected = (id) {
      WindowController.fromWindowId(windowId())
          .setTitle(getWindowNameWithId(id));
    };
    tabController.onRemoved = (_, id) => onRemoveId(id);
    addFileTransferTab(params['id'], params,
        sendFiles: LocalFileToSend.listFromJson(params['send_files']),
        toPath: params['to_path'] as String?,
        downloadFiles: RemoteFileToDownload.listFromJson(params['download_files']),
        toLocalDir: params['to_local_dir'] as String?);
  }

  /// Add the tab of the peer, which connects the file transfer session.
  void addFileTransferTab(dynamic id, Map<String, dynamic> args,
      {List<LocalFileToSend> sendFiles = const [],
      List<RemoteFileToDownload> downloadFiles = const [],
      String? toPath,
      String? toLocalDir}) {
    tabController.add(TabInfo(
        key: id,
        label: id,
        selectedIcon: selectedIcon,
        unselectedIcon: unselectedIcon,
        onTabCloseButton: () async {
          if (await desktopTryShowTabAuditDialogCloseCancelled(
            id: id,
            tabController: tabController,
          )) {
            return;
          }
          tabController.closeBy(id);
        },
        page: FileManagerPage(
          key: ValueKey(id),
          id: id,
          password: args['password'],
          isSharedPassword: args['isSharedPassword'],
          tabController: tabController,
          forceRelay: args['forceRelay'],
          connToken: args['connToken'],
          sendFiles: sendFiles,
          toPath: toPath,
          downloadFiles: downloadFiles,
          toLocalDir: toLocalDir,
        )));
  }

  @override
  void initState() {
    super.initState();

    rustDeskWinManager.setMethodHandler((call, fromWindowId) async {
      debugPrint(
          "[FileTransfer] call ${call.method} with args ${call.arguments} from window $fromWindowId to ${windowId()}");
      // for simplify, just replace connectionId
      if (call.method == kWindowEventNewFileTransfer) {
        final args = jsonDecode(call.arguments);
        final id = args['id'];
        final sendFiles = LocalFileToSend.listFromJson(args['send_files']);
        // The files have to be sent by the file transfer page, which already
        // exists if the peer has a tab in this window.
        final exists =
            tabController.state.value.tabs.any((tab) => tab.key == id);
        windowOnTop(windowId());
        addFileTransferTab(id, args,
            sendFiles: sendFiles, toPath: args['to_path'] as String?);
        if (exists && sendFiles.isNotEmpty) {
          final page = tabController.widget(id);
          if (page is FileManagerPage) {
            page.sendLocalFiles(sendFiles, toPath: args['to_path'] as String?);
          }
        }
      } else if (call.method == kWindowEventGetFilesTargetDir) {
        // Answer the remote directory which is opened here, it is the default
        // target directory of the files which are dropped on a session window.
        final id = jsonDecode(call.arguments)['id'];
        final page = tabController.widget(id);
        return page is FileManagerPage ? (page.remoteDir() ?? '') : '';
      } else if (call.method == kWindowEventSendFilesToPeerWithTargetDir) {
        final args = jsonDecode(call.arguments);
        final id = args['id'];
        final sendFiles = LocalFileToSend.listFromJson(args['files']);
        final toPath = args['toPath'] as String?;
        if (tabController.state.value.tabs.any((tab) => tab.key == id)) {
          final page = tabController.widget(id);
          if (page is FileManagerPage) {
            windowOnTop(windowId());
            page.sendLocalFiles(sendFiles, toPath: toPath);
          }
        } else {
          // The peer has no tab in this window, add it, the files are sent as
          // soon as its session is connected.
          windowOnTop(windowId());
          addFileTransferTab(id, args, sendFiles: sendFiles, toPath: toPath);
        }
      } else if (call.method == kWindowEventDownloadFilesToLocal) {
        final args = jsonDecode(call.arguments);
        final id = args['id'];
        final downloadFiles = RemoteFileToDownload.listFromJson(args['files']);
        final toLocalDir = args['toLocalDir'] as String?;
        if (tabController.state.value.tabs.any((tab) => tab.key == id)) {
          final page = tabController.widget(id);
          if (page is FileManagerPage) {
            windowOnTop(windowId());
            page.downloadFromRemote(downloadFiles, toLocalDir: toLocalDir);
          }
        } else {
          // The peer has no tab in this window, add it, the files are
          // downloaded as soon as its session is connected.
          windowOnTop(windowId());
          addFileTransferTab(id, args,
              downloadFiles: downloadFiles, toLocalDir: toLocalDir);
        }
      } else if (call.method == "onDestroy") {
        tabController.clear();
      } else if (call.method == kWindowActionRebuild) {
        reloadCurrentWindow();
      }
    });
    Future.delayed(Duration.zero, () {
      restoreWindowPosition(WindowType.FileTransfer, windowId: windowId());
    });
  }

  @override
  Widget build(BuildContext context) {
    final child = Scaffold(
        backgroundColor: Theme.of(context).cardColor,
        body: DesktopTab(
          controller: tabController,
          onWindowCloseButton: handleWindowCloseButton,
          tail: const AddButton(),
          selectedBorderColor: MyTheme.accent,
          labelGetter: DesktopTab.tablabelGetter,
        ));
    final tabWidget = isLinux
        ? buildVirtualWindowFrame(context, child)
        : workaroundWindowBorder(
            context,
            Container(
              decoration: BoxDecoration(
                  border: Border.all(color: MyTheme.color(context).border!)),
              child: child,
            ));
    return isMacOS || kUseCompatibleUiMode
        ? tabWidget
        : SubWindowDragToResizeArea(
            child: tabWidget,
            resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
            enableResizeEdges: subWindowManagerEnableResizeEdges,
            windowId: stateGlobal.windowId,
          );
  }

  void onRemoveId(String id) {
    if (tabController.state.value.tabs.isEmpty) {
      WindowController.fromWindowId(windowId()).close();
    }
  }

  int windowId() {
    return widget.params["windowId"];
  }

  Future<bool> handleWindowCloseButton() async {
    final connLength = tabController.state.value.tabs.length;
    if (connLength == 1) {
      if (await desktopTryShowTabAuditDialogCloseCancelled(
        id: tabController.state.value.tabs[0].key,
        tabController: tabController,
      )) {
        return false;
      }
    }
    if (connLength <= 1) {
      tabController.clear();
      return true;
    } else {
      final bool res;
      if (!option2bool(kOptionEnableConfirmClosingTabs,
          bind.mainGetLocalOption(key: kOptionEnableConfirmClosingTabs))) {
        res = true;
      } else {
        res = await closeConfirmDialog();
      }
      if (res) {
        tabController.clear();
      }
      return res;
    }
  }
}
