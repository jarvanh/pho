import 'package:flutter/material.dart';
import 'event_bus.dart';
import 'package:img_syncer/asset.dart';
import 'dart:async';
import 'package:photo_manager/photo_manager.dart';
import 'package:img_syncer/storage/storage.dart';

StateModel stateModel = StateModel();
AssetModel assetModel = AssetModel();
SelectionModeModel selectionModeModel = SelectionModeModel();

class StateModel extends ChangeNotifier {
  String localFolder = "";
  bool isRemoteStorageSetted = false;
  List<String> notSyncedNames = [];

  void setLocalFolder(String folder) {
    if (localFolder == folder) return;
    localFolder = folder;
    eventBus.fire(LocalRefreshEvent());
    notifyListeners();
  }

  void setRemoteStorageSetted(bool setted) {
    if (isRemoteStorageSetted == setted) return;
    isRemoteStorageSetted = setted;
    eventBus.fire(RemoteRefreshEvent());
    notifyListeners();
  }

  void setNotSyncedPhotos(List<String> names) {
    notSyncedNames = names;
    notifyListeners();
  }
}

class SelectionModeModel extends ChangeNotifier {
  bool _isSelectionMode = false;

  bool get isSelectionMode => _isSelectionMode;

  void setSelectionMode(bool mode) {
    if (_isSelectionMode == mode) return;
    _isSelectionMode = mode;
    notifyListeners();
  }
}

class AssetModel extends ChangeNotifier {
  AssetModel() {
    eventBus.on<LocalRefreshEvent>().listen((event) => refreshLocal());
    eventBus.on<RemoteRefreshEvent>().listen((event) => refreshRemote());
  }
  String selectedAlbum = "";
  List<Asset> localAssets = [];
  List<Asset> remoteAssets = [];
  int columCount = 3;
  int pageSize = 50;
  bool localHasMore = true;
  bool remoteHasMore = true;
  Completer<bool>? localGetting;
  Completer<bool>? remoteGetting;

  void setAlbum(String album) {
    if (selectedAlbum == album) return;
    selectedAlbum = album;
    refreshLocal();
  }

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
    final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList();
    for (var path in paths) {
      if (selectedAlbum == path.name) {
        final newpath = await path.fetchPathProperties(
            filterOptionGroup: FilterOptionGroup(
          orders: [
            const OrderOption(
              type: OrderOptionType.updateDate,
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

    remoteGetting?.complete(true);
    remoteGetting = null;
  }
}
