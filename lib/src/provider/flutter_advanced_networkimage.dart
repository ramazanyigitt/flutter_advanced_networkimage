import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui show Codec, hashValues;

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'package:flutter_advanced_networkimage/src/disk_cache.dart';
import 'package:flutter_advanced_networkimage/src/utils.dart';

typedef Future<Uint8List> ImageProcessing(Uint8List data);

/// Fetches the given URL from the network, associating it with some options.
class AdvancedNetworkImage extends ImageProvider<AdvancedNetworkImage> {
  AdvancedNetworkImage(
    this.url, {
    this.scale: 1.0,
    this.header,
    this.useDiskCache: false,
    this.retryLimit: 5,
    this.retryDuration: const Duration(milliseconds: 500),
    this.retryDurationFactor: 1.5,
    this.timeoutDuration: const Duration(seconds: 5),
    this.loadedCallback,
    this.loadFailedCallback,
    this.loadedFromDiskCacheCallback,
    this.fallbackAssetImage,
    this.fallbackImage,
    this.cacheRule,
    this.loadingProgress,
    this.getRealUrl,
    this.preProcessing,
    this.postProcessing,
    this.disableMemoryCache: false,
    this.printError = false,
    this.skipRetryStatusCode,
  })  : assert(url != null),
        assert(scale != null),
        assert(useDiskCache != null),
        assert(retryLimit != null),
        assert(retryDuration != null),
        assert(retryDurationFactor != null),
        assert(timeoutDuration != null),
        assert(disableMemoryCache != null),
        assert(printError != null);

  /// The URL from which the image will be fetched.
  final String url;

  /// The scale to place in the [ImageInfo] object of the image.
  final double scale;

  /// The HTTP headers that will be used with [http] to fetch image from network.
  final Map<String, String> header;

  /// The flag control the disk cache will be used or not.
  final bool useDiskCache;

  /// The retry limit will be used to limit the retry attempts.
  final int retryLimit;

  /// The retry duration will give the interval between the retries.
  final Duration retryDuration;

  /// Apply factor to control retry duration between retry.
  final double retryDurationFactor;

  /// The timeout duration will give the timeout to a fetching function.
  final Duration timeoutDuration;

  /// The callback will fire when the image loaded.
  final VoidCallback loadedCallback;

  /// The callback will fire when the image failed to load.
  final VoidCallback loadFailedCallback;

  /// The callback will fire when the image loaded from DiskCache.
  VoidCallback loadedFromDiskCacheCallback;

  /// Displays image from an asset bundle when the image failed to load.
  final String fallbackAssetImage;

  /// The image will be displayed when the image failed to load
  /// and [fallbackAssetImage] is null.
  final Uint8List fallbackImage;

  /// Disk cache rules for advanced control.
  final CacheRule cacheRule;

  /// Report loading progress and data when fetching image.
  LoadingProgress loadingProgress;

  /// Extract the real url before fetching.
  final UrlResolver getRealUrl;

  /// Receive the data([Uint8List]) and do some manipulations before saving.
  final ImageProcessing preProcessing;

  /// Receive the data([Uint8List]) and do some manipulations after saving.
  final ImageProcessing postProcessing;

  /// If set to enable, the image will skip [ImageCache].
  ///
  /// It is not recommended to disable momery cache, because image provider
  /// will be called a lot of times. If you do not enable [useDiskCache],
  /// image provider will fetch a lot of times. So do not use this option
  /// in production.
  ///
  /// If you want to use the same url with different [fallbackImage],
  /// you should make different [==].
  /// For example, you can set different [retryLimit].
  /// If you enable [useDiskCache], you can set different [differentId]
  /// with the same `() => Future.value(sameUrl)` in [getRealUrl].
  final bool disableMemoryCache;

  /// Print error messages.
  final bool printError;

  /// The [HttpStatus] code that you can skip retrying if you meet them.
  final List<int> skipRetryStatusCode;

  ImageStream resolve(ImageConfiguration configuration) {
    assert(configuration != null);
    final ImageStream stream = ImageStream();
    obtainKey(configuration).then<void>((AdvancedNetworkImage key) {
      if (key.disableMemoryCache) {
        stream.setCompleter(
            load(key, PaintingBinding.instance.instantiateImageCodec));
      } else {
        final ImageStreamCompleter completer =
            PaintingBinding.instance.imageCache.putIfAbsent(
                key,
                () =>
                    load(key, PaintingBinding.instance.instantiateImageCodec));
        if (completer != null) stream.setCompleter(completer);
      }
    });
    return stream;
  }

  @override
  Future<AdvancedNetworkImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<AdvancedNetworkImage>(this);
  }

  @override
  ImageStreamCompleter load(AdvancedNetworkImage key, DecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key),
      scale: key.scale,
      informationCollector: () sync* {
        yield DiagnosticsProperty<ImageProvider>('Image provider', this);
        yield DiagnosticsProperty<AdvancedNetworkImage>('Image key', key);
      },
    );
  }

  Future<ui.Codec> _loadAsync(AdvancedNetworkImage key) async {
    assert(key == this);

    String uId = uid(key.url);

    if (useDiskCache) {
      try {
        Uint8List _diskCache = await _loadFromDiskCache(key, uId);
        if (_diskCache != null) {
          if (key.postProcessing != null)
            _diskCache = (await key.postProcessing(_diskCache)) ?? _diskCache;
          if (key.loadedCallback != null) key.loadedCallback();
          return await PaintingBinding.instance
              .instantiateImageCodec(_diskCache);
        }
      } catch (e) {
        if (key.printError) debugPrint(e.toString());
      }
    } else {
      Uint8List imageData = await loadFromRemote(
        key.url,
        key.header,
        key.retryLimit,
        key.retryDuration,
        key.retryDurationFactor,
        key.timeoutDuration,
        key.loadingProgress,
        key.getRealUrl,
        printError: key.printError,
      );
      if (imageData != null) {
        if (key.postProcessing != null)
          imageData = (await key.postProcessing(imageData)) ?? imageData;
        if (key.loadedCallback != null) key.loadedCallback();
        return await PaintingBinding.instance.instantiateImageCodec(imageData);
      }
    }

    if (key.loadFailedCallback != null) key.loadFailedCallback();
    if (key.fallbackAssetImage != null) {
      ByteData imageData = await rootBundle.load(key.fallbackAssetImage);
      return await PaintingBinding.instance
          .instantiateImageCodec(imageData.buffer.asUint8List());
    }
    if (key.fallbackImage != null)
      return await PaintingBinding.instance
          .instantiateImageCodec(key.fallbackImage);

    return Future.error(StateError('Failed to load $url.'));
  }

  @override
  bool operator ==(dynamic other) {
    if (other.runtimeType != runtimeType) return false;
    final AdvancedNetworkImage typedOther = other;
    return url == typedOther.url &&
        scale == typedOther.scale &&
        useDiskCache == typedOther.useDiskCache &&
        retryLimit == typedOther.retryLimit &&
        retryDurationFactor == typedOther.retryDurationFactor &&
        retryDuration == typedOther.retryDuration;
  }

  @override
  int get hashCode => ui.hashValues(url, scale, useDiskCache, retryLimit,
      retryDuration, retryDurationFactor, timeoutDuration);

  @override
  String toString() => '$runtimeType('
      '"$url",'
      'scale: $scale,'
      'header: $header,'
      'useDiskCache: $useDiskCache,'
      'retryLimit: $retryLimit,'
      'retryDuration: $retryDuration,'
      'retryDurationFactor: $retryDurationFactor,'
      'timeoutDuration: $timeoutDuration'
      ')';
}

/// Load the disk cache
///
/// Check the following conditions: (no [CacheRule])
/// 1. Check if cache directory exist. If not exist, create it.
/// 2. Check if cached file(uid) exist. If yes, load the cache,
///   otherwise go to download step.
Future<Uint8List> _loadFromDiskCache(
    AdvancedNetworkImage key, String uId) async {
  if (key.cacheRule == null) {
    Directory _cacheImagesDirectory =
        Directory(join((await getTemporaryDirectory()).path, 'imagecache'));
    if (_cacheImagesDirectory.existsSync()) {
      File _cacheImageFile = File(join(_cacheImagesDirectory.path, uId));
      if (_cacheImageFile.existsSync()) {
        if (key.loadedFromDiskCacheCallback != null)
          key.loadedFromDiskCacheCallback();
        return await _cacheImageFile.readAsBytes();
      }
    } else {
      await _cacheImagesDirectory.create();
    }

    Uint8List imageData = await loadFromRemote(
      key.url,
      key.header,
      key.retryLimit,
      key.retryDuration,
      key.retryDurationFactor,
      key.timeoutDuration,
      key.loadingProgress,
      key.getRealUrl,
      skipRetryStatusCode: key.skipRetryStatusCode,
      printError: key.printError,
    );
    if (imageData != null) {
      if (key.preProcessing != null)
        imageData = (await key.preProcessing(imageData)) ?? imageData;
      await (File(join(_cacheImagesDirectory.path, uId)))
          .writeAsBytes(imageData);
      return imageData;
    }
  } else {
    DiskCache diskCache = DiskCache()..printError = key.printError;
    Uint8List data = await diskCache.load(uId, rule: key.cacheRule);
    if (data != null) {
      if (key.loadedFromDiskCacheCallback != null)
        key.loadedFromDiskCacheCallback();
      return data;
    }

    data = await loadFromRemote(
      key.url,
      key.header,
      key.retryLimit,
      key.retryDuration,
      key.retryDurationFactor,
      key.timeoutDuration,
      key.loadingProgress,
      key.getRealUrl,
      printError: key.printError,
    );
    if (data != null) {
      if (key.preProcessing != null)
        data = (await key.preProcessing(data)) ?? data;
      await diskCache.save(uId, data, key.cacheRule);
      return data;
    }
  }

  return null;
}
