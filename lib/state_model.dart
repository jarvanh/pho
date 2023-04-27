// ignore_for_file: deprecated_member_use

import 'dart:io';

import 'package:flutter/material.dart';
import 'event_bus.dart';
import 'package:img_syncer/asset.dart';
import 'dart:async';
import 'package:photo_manager/photo_manager.dart';
import 'package:img_syncer/storage/storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:mime/mime.dart';
import 'package:img_syncer/proto/img_syncer.pbgrpc.dart';

SettingModel settingModel = SettingModel();
AssetModel assetModel = AssetModel();
StateModel stateModel = StateModel();

enum Drive { smb, webDav }

Map<Drive, String> driveName = {
  Drive.smb: 'SMB',
  Drive.webDav: 'WebDAV',
};

class SettingModel extends ChangeNotifier {
  String localFolder = "";
  String? localFolderAbsPath;
  bool isRemoteStorageSetted = false;

  void setLocalFolder(String folder) {
    if (localFolder == folder) return;
    localFolder = folder;
    localFolderAbsPath = null;
    eventBus.fire(LocalRefreshEvent());
    notifyListeners();
  }

  void setRemoteStorageSetted(bool setted) {
    if (isRemoteStorageSetted == setted) return;
    isRemoteStorageSetted = setted;
    eventBus.fire(RemoteRefreshEvent());
    notifyListeners();
  }
}

class StateModel extends ChangeNotifier {
  bool _isSelectionMode = false;
  bool isUploading = false;
  bool isDownloading = false;
  List<String> notSyncedNames = [];

  bool get isSelectionMode => _isSelectionMode;

  void setUploadState(bool state) {
    if (isUploading == state) return;
    isUploading = state;
    notifyListeners();
  }

  void setDownloadState(bool state) {
    if (isDownloading == state) return;
    isDownloading = state;
    notifyListeners();
  }

  void setSelectionMode(bool mode) {
    if (_isSelectionMode == mode) return;
    _isSelectionMode = mode;
    notifyListeners();
  }

  void setNotSyncedPhotos(List<String> names) {
    notSyncedNames = names;
    notifyListeners();
  }
}

class AssetModel extends ChangeNotifier {
  AssetModel() {
    eventBus.on<LocalRefreshEvent>().listen((event) => refreshLocal());
    eventBus.on<RemoteRefreshEvent>().listen((event) => refreshRemote());
  }
  List<Asset> localAssets = [];
  List<Asset> remoteAssets = [];
  int columCount = 3;
  int pageSize = 50;
  bool localHasMore = true;
  bool remoteHasMore = true;
  Completer<bool>? localGetting;
  Completer<bool>? remoteGetting;

  Future<void> refreshLocal() async {
    if (localGetting != null) {
      await localGetting!.future;
    }
    localHasMore = true;
    localAssets = [];
    notifyListeners();
    await getLocalPhotos();
  }

  Future<void> refreshRemote() async {
    if (remoteGetting != null) {
      await remoteGetting!.future;
    }
    remoteHasMore = true;
    remoteAssets = [];
    notifyListeners();
    remoteGetting = null;
    await getRemotePhotos();
  }

  Future<void> getLocalPhotos() async {
    if (localGetting != null) {
      await localGetting?.future;
      return;
    }
    localGetting = Completer<bool>();
    final offset = localAssets.length;
    final PermissionState _ps = await PhotoManager.requestPermissionExtend();
    final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      hasAll: true,
    );

    // choose the folder has most photos
    if (settingModel.localFolder == "") {
      int max = 0;
      for (var path in paths) {
        if (path.assetCount > max) {
          max = path.assetCount;
          settingModel.setLocalFolder(path.name);
        }
      }
    }

    for (var path in paths) {
      if (settingModel.localFolder == path.name) {
        final newpath = await path.fetchPathProperties(
            filterOptionGroup: FilterOptionGroup(
          orders: [
            const OrderOption(
              type: OrderOptionType.createDate,
              asc: false,
            ),
          ],
        ));
        final List<AssetEntity> entities = await newpath!
            .getAssetListRange(start: offset, end: offset + pageSize);
        if (entities.length < pageSize) {
          localHasMore = false;
        }
        for (var entity in entities) {
          if (entity.type == AssetType.image) {
            final asset = Asset(local: entity);
            if (settingModel.localFolderAbsPath == null) {
              final file = await entity.file;
              if (file != null) {
                settingModel.localFolderAbsPath = file.parent.path;
              }
            }
            await asset.thumbnailDataAsync();
            localAssets.add(asset);
            notifyListeners();
          }
        }
      }
    }

    localGetting?.complete(true);
    localGetting = null;
  }

  Future<void> getRemotePhotos() async {
    if (remoteGetting != null) {
      await remoteGetting!.future;
      return;
    }
    remoteGetting = Completer<bool>();
    final offset = remoteAssets.length;
    try {
      final List<RemoteImage> images =
          await storage.listImages("", offset, pageSize);
      if (images.length < pageSize) {
        remoteHasMore = false;
      }
      for (var image in images) {
        try {
          final asset = Asset(remote: image);
          final thumbnailData = await asset.thumbnailDataAsync();
          remoteAssets.add(asset);
          notifyListeners();
        } catch (e) {
          print(e);
        }
      }
    } catch (e) {
      print("get remote photos failed: $e");
    }

    remoteGetting?.complete(true);
    remoteGetting = null;
  }
}

Future<void> scanFile(String filePath) async {
  if (Platform.isAndroid) {
    try {
      final directory = await getExternalStorageDirectory();
      final path = directory?.path ?? '';
      final mimeType = lookupMimeType(filePath);
      final Map<String, dynamic> params = {
        'path': filePath,
        'volumeName': 'external_primary',
        'relativePath': filePath.replaceFirst('$path/', ''),
        'mimeType': mimeType,
      };

      await MethodChannel('com.example.img_syncer/RunGrpcServer')
          .invokeMethod('scanFile', params);
    } on PlatformException catch (e) {
      print('Failed to scan file $filePath: ${e.message}');
    }
  }
}

Future<void> refreshUnsynchronizedPhotos() async {
  final localFloder = settingModel.localFolder;
  final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList();
  for (var path in paths) {
    if (path.name == localFloder) {
      final newpath = await path.fetchPathProperties(
          filterOptionGroup: FilterOptionGroup(
        orders: [
          const OrderOption(
            type: OrderOptionType.createDate,
            asc: false,
          ),
        ],
      ));
      FilterNotUploadedRequest req =
          FilterNotUploadedRequest(names: List<String>.empty(growable: true));
      int offset = 0;
      int pageSize = 100;

      while (true) {
        final List<AssetEntity> assets = await newpath!
            .getAssetListRange(start: offset, end: offset + pageSize);
        if (assets.isEmpty) {
          break;
        }
        for (var asset in assets) {
          if (asset.type == AssetType.image && asset.title != null) {
            req.names.add(asset.title!);
          }
        }
        offset += pageSize;
      }
      final rsp = await storage.cli.filterNotUploaded(req);
      if (rsp.success) {
        stateModel.setNotSyncedPhotos(rsp.notUploaed);
      } else {
        throw Exception("Refresh unsynchronized photos failed: ${rsp.message}");
      }
    }
  }
}
