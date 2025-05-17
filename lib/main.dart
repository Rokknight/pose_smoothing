import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:battery_plus/battery_plus.dart';
import 'package:camera/camera.dart';
import 'package:camera/camera.dart' as material;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:system_info2/system_info2.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vector_math/vector_math_64.dart';

void main() async {
  material.WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await _requestCameraPermission();
  final cameras = await availableCameras();
  material.runApp(MyApp(cameras: cameras));
}

Future<void> _requestCameraPermission() async {
  if (!await Permission.camera.status.isGranted) {
    await Permission.camera.request();
  }
}

class MyApp extends material.StatelessWidget {
  final List<CameraDescription> cameras;
  const MyApp({super.key, required this.cameras});

  @override
  material.Widget build(material.BuildContext context) {
    return material.MaterialApp(
      theme: material.ThemeData.dark(),
      debugShowCheckedModeBanner: false,
      showPerformanceOverlay: true,
      home: PoseDetectionScreen(cameras: cameras),
    );
  }
}

// Enhanced exponential smoother with adaptive alpha
class PoseSmoother {
  final Map<PoseLandmarkType, Vector2> previousLandmarks = {};
  final Map<PoseLandmarkType, Vector2> velocities = {};
  final double baseAlpha;
  final double minAlpha;
  final bool enabled;

  PoseSmoother({
    this.baseAlpha = 0.4,
    this.minAlpha = 0.1,
    required this.enabled,
  });

  List<PoseLandmark> smoothPose(Map<PoseLandmarkType, PoseLandmark> landmarksMap) {
    if (!enabled) return landmarksMap.values.toList();

    final smoothedLandmarks = <PoseLandmark>[];
    final stopwatch = Stopwatch()..start();

    for (var landmark in landmarksMap.values) {
      final type = landmark.type;
      final currentPos = Vector2(landmark.x, landmark.y);

      final likelihood = landmark.likelihood.clamp(0.1, 1.0);
      final adaptiveAlpha = minAlpha + (baseAlpha - minAlpha) * likelihood;

      previousLandmarks.putIfAbsent(type, () => currentPos);
      velocities.putIfAbsent(type, () => Vector2.zero());

      final prevPos = previousLandmarks[type]!;
      final prevVelocity = velocities[type]!;
      final smoothedPos = prevPos * (1 - adaptiveAlpha) + currentPos * adaptiveAlpha;
      final velocity = (smoothedPos - prevPos) * 60.0;
      velocities[type] = velocity;
      previousLandmarks[type] = smoothedPos;
      smoothedLandmarks.add(PoseLandmark(
        type: type,
        x: smoothedPos.x,
        y: smoothedPos.y,
        z: landmark.z,
        likelihood: landmark.likelihood,
      ));
    }

    stopwatch.stop();
    PerformanceTracker().log(
        'Экспоненциальное сглаживание: ${stopwatch.elapsedMicroseconds / 1000.0} мс');

    return smoothedLandmarks;
  }
}

enum SmoothingMode { none, exponential }

class PoseDetectionScreen extends material.StatefulWidget {
  final List<CameraDescription> cameras;
  const PoseDetectionScreen({super.key, required this.cameras});

  @override
  _PoseDetectionScreenState createState() => _PoseDetectionScreenState();
}

class _PoseDetectionScreenState extends material.State<PoseDetectionScreen> {
  late CameraController _controller;
  late PoseDetector _poseDetector;
  late PerformanceTracker _performanceTracker;
  late PoseSmoother _poseSmoother;
  bool _isProcessing = false;
  List<Pose> _poses = [];
  String _debugInfo = 'Инициализация...';
  bool _useAccurateModel = false;
  ResolutionPreset _resolution = ResolutionPreset.low;
  bool _showDebugFrame = true;
  int _cameraIndex = 0;
  SmoothingMode _smoothingMode = SmoothingMode.none;

  double get yOffset => _resolution == ResolutionPreset.low ? -150.0 : -70.0;

  @override
  void initState() {
    super.initState();
    _performanceTracker = PerformanceTracker();
    _initializeCamera();
    _initializePoseDetector();
    _poseSmoother = PoseSmoother(enabled: _smoothingMode == SmoothingMode.exponential);
    Timer.periodic(Duration(seconds: 30), (_) => _performanceTracker.logMetrics(_smoothingMode));
  }

  Future<void> _initializeCamera() async {
    try {
      _controller = CameraController(widget.cameras[_cameraIndex], _resolution);
      await _controller.initialize();
      if (!mounted) return;
      await _controller.startImageStream(_processCameraImage);
      _performanceTracker.log('Камера инициализирована: ${_controller.description.name}');
      setState(() => _updateDebugInfo());
    } catch (e) {
      _performanceTracker.log('Ошибка камеры: $e');
      setState(() => _debugInfo = 'Ошибка камеры: $e');
    }
  }

  void _initializePoseDetector() {
    _poseDetector = PoseDetector(
      options: PoseDetectorOptions(
        model: _useAccurateModel ? PoseDetectionModel.accurate : PoseDetectionModel.base,
        mode: PoseDetectionMode.stream,
      ),
    );
  }

  void _updateDebugInfo() {
    final camera = widget.cameras[_cameraIndex];
    final cameraName = camera.lensDirection == CameraLensDirection.front ? 'Передняя' : 'Задняя';
    final previewSize = _controller.value.previewSize;
    final resolutionStr = previewSize != null
        ? '${previewSize.width.toInt()}×${previewSize.height.toInt()}'
        : 'Неизвестно';
    _debugInfo =
    'Камера: $cameraName\nРазрешение: $resolutionStr\nРежим: $_smoothingMode\nПоз: ${_poses.length}, Кадр: ${(_performanceTracker.lastFrameTime ?? 0.0).toStringAsFixed(2)} мс, FPS: ${(_performanceTracker.lastFps ?? 0.0).toStringAsFixed(2)}\nJitter: ${(_performanceTracker.lastJitter ?? 0.0).toStringAsFixed(2)} px, Latency: ${(_performanceTracker.lastLatency ?? 0.0).toStringAsFixed(2)} мс';
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isProcessing) return;
    _isProcessing = true;

    final frameStartTime = DateTime.now();
    final stopwatch = Stopwatch()..start();
    try {
      final inputImage = await compute(_convertCameraImage, {
        'image': image,
        'camera': widget.cameras[_cameraIndex],
      });

      final poses = await _poseDetector.processImage(inputImage);
      final smoothedPoses = poses.map((pose) {
        final smoothedLandmarks = _poseSmoother.smoothPose(pose.landmarks);
        return Pose(landmarks: {for (var lm in smoothedLandmarks) lm.type: lm});
      }).toList();

      stopwatch.stop();
      final frameTime = stopwatch.elapsedMilliseconds.toDouble();
      final fps = frameTime > 0 ? 1000.0 / frameTime : 0.0;
      final latency = DateTime.now().difference(frameStartTime).inMilliseconds.toDouble();

      _performanceTracker.recordFrameTime(frameTime, fps, latency, _poseSmoother.velocities, _smoothingMode);
      _performanceTracker.log('Обработан кадр, поз: ${poses.length}, режим: $_smoothingMode');

      setState(() {
        _poses = smoothedPoses;
        _updateDebugInfo();
      });
    } catch (e) {
      _performanceTracker.log('Ошибка обработки кадра: $e');
      setState(() => _debugInfo = 'Ошибка: $e');
    } finally {
      _isProcessing = false;
    }
  }

  static InputImage _convertCameraImage(Map<String, dynamic> args) {
    final CameraImage image = args['image'];
    final CameraDescription camera = args['camera'];

    final WriteBuffer allBytes = WriteBuffer();
    for (var plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    InputImageRotation rotation;
    switch (camera.sensorOrientation) {
      case 90:
        rotation = InputImageRotation.rotation90deg;
        break;
      case 270:
        rotation = InputImageRotation.rotation270deg;
        break;
      default:
        rotation = InputImageRotation.rotation0deg;
    }

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );
  }

  Future<void> _switchCamera() async {
    _cameraIndex = (_cameraIndex + 1) % widget.cameras.length;
    await _controller.dispose();
    await _initializeCamera();
    setState(() => _updateDebugInfo());
  }

  Future<void> _updateSettings({
    bool? useAccurateModel,
    ResolutionPreset? resolution,
    bool? showDebugFrame,
    SmoothingMode? smoothingMode,
  }) async {
    if (useAccurateModel != null) {
      _useAccurateModel = useAccurateModel;
      await _poseDetector.close();
      _initializePoseDetector();
      _performanceTracker.log('Модель: ${_useAccurateModel ? "точная" : "базовая"}');
    }
    if (resolution != null) {
      _resolution = resolution;
      await _controller.dispose();
      await _initializeCamera();
      _performanceTracker.log('Разрешение: $resolution');
    }
    if (showDebugFrame != null) {
      _showDebugFrame = showDebugFrame;
      _performanceTracker.log('Отладочный кадр: $showDebugFrame');
    }
    if (smoothingMode != null) {
      _smoothingMode = smoothingMode;
      _poseSmoother = PoseSmoother(enabled: smoothingMode == SmoothingMode.exponential);
      _performanceTracker.log('Режим сглаживания: $smoothingMode');
    }
    setState(() => _updateDebugInfo());
  }

  void _showSettingsDialog() {
    material.showDialog(
      context: context,
      builder: (context) => material.AlertDialog(
        title: const material.Text('Настройки'),
        content: material.SingleChildScrollView(
          child: material.Column(
            mainAxisSize: material.MainAxisSize.min,
            children: [
              material.SwitchListTile(
                title: const material.Text('Точная модель'),
                value: _useAccurateModel,
                onChanged: (val) {
                  material.Navigator.pop(context);
                  _updateSettings(useAccurateModel: val);
                },
              ),
              material.SwitchListTile(
                title: const material.Text('Показать отладку'),
                value: _showDebugFrame,
                onChanged: (val) {
                  material.Navigator.pop(context);
                  _updateSettings(showDebugFrame: val);
                },
              ),
              material.DropdownButton<ResolutionPreset>(
                value: _resolution,
                items: [ResolutionPreset.low, ResolutionPreset.high]
                    .map((res) => material.DropdownMenuItem(
                  value: res,
                  child: material.Text(res.toString().split('.').last),
                ))
                    .toList(),
                onChanged: (val) {
                  if (val != null) {
                    material.Navigator.pop(context);
                    _updateSettings(resolution: val);
                  }
                },
              ),
              material.DropdownButton<SmoothingMode>(
                value: _smoothingMode,
                items: SmoothingMode.values
                    .map((mode) => material.DropdownMenuItem(
                  value: mode,
                  child: material.Text(mode.toString().split('.').last),
                ))
                    .toList(),
                onChanged: (val) {
                  if (val != null) {
                    material.Navigator.pop(context);
                    _updateSettings(smoothingMode: val);
                  }
                },
              ),
            ],
          ),
        ),
        actions: [
          material.TextButton(
            onPressed: () => material.Navigator.pop(context),
            child: const material.Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _poseDetector.close();
    _performanceTracker.dispose();
    super.dispose();
  }

  @override
  material.Widget build(material.BuildContext context) {
    if (!_controller.value.isInitialized) {
      return const material.Scaffold(body: material.Center(child: material.CircularProgressIndicator()));
    }

    final size = material.MediaQuery.of(context).size;
    final frameWidth = size.width;

    return material.Scaffold(
      appBar: material.AppBar(
        title: const material.Text('Детектор поз'),
        actions: [
          material.IconButton(
            icon: material.Icon(material.Icons.flash_on,
                color: _useAccurateModel ? material.Colors.grey : material.Colors.white),
            onPressed: () => _updateSettings(useAccurateModel: false),
          ),
          material.IconButton(
            icon: material.Icon(material.Icons.center_focus_strong,
                color: _useAccurateModel ? material.Colors.white : material.Colors.grey),
            onPressed: () => _updateSettings(useAccurateModel: true),
          ),
          material.IconButton(
              icon: const material.Icon(material.Icons.cameraswitch), onPressed: _switchCamera),
          material.IconButton(
              icon: const material.Icon(material.Icons.settings), onPressed: _showSettingsDialog),
        ],
      ),
      body: material.Stack(
        children: [
          material.CameraPreview(_controller),
          material.Positioned(
            right: 0,
            top: 10,
            bottom: 10,
            child: material.Container(
              width: frameWidth,
              decoration: material.BoxDecoration(
                border: material.Border.all(color: material.Colors.green, width: 2),
              ),
              child: material.CustomPaint(
                painter: SkeletonPainter(
                  poses: _poses,
                  imageSize: Size(
                    _controller.value.previewSize!.height,
                    _controller.value.previewSize!.width,
                  ),
                  frameSize: size,
                  yOffset: yOffset,
                ),
              ),
            ),
          ),
          if (_showDebugFrame)
            material.Positioned(
              bottom: 10,
              left: 10,
              child: material.Container(
                color: material.Colors.black54,
                padding: const material.EdgeInsets.all(8),
                child: material.Text(
                  _debugInfo,
                  style: const material.TextStyle(color: material.Colors.white, fontSize: 14),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class SkeletonPainter extends material.CustomPainter {
  final List<Pose> poses;
  final Size imageSize;
  final Size frameSize;
  final double yOffset;

  SkeletonPainter({
    required this.poses,
    required this.imageSize,
    required this.frameSize,
    this.yOffset = -70.0,
  });

  @override
  void paint(material.Canvas canvas, Size size) {
    final pointPaint = material.Paint()
      ..color = material.Colors.red
      ..style = material.PaintingStyle.fill;

    final linePaint = material.Paint()
      ..color = material.Colors.blue
      ..style = material.PaintingStyle.stroke
      ..strokeWidth = 2;

    for (final pose in poses) {
      final landmarks = pose.landmarks;
      final Map<PoseLandmarkType, material.Offset> scaledPoints = {};

      landmarks.forEach((type, landmark) {
        final scaleX = frameSize.width / imageSize.width;
        final scaleY = frameSize.height / imageSize.height;
        final scale = math.min(scaleX, scaleY);

        final dx = (frameSize.width - imageSize.width * scale) / 2;
        final dy = (frameSize.height - imageSize.height * scale) / 2 + yOffset;

        final point = material.Offset(
          landmark.x * scale + dx,
          landmark.y * scale + dy,
        );
        scaledPoints[type] = point;
      });

      scaledPoints.values.forEach((point) {
        canvas.drawCircle(point, 5, pointPaint);
      });

      const List<(PoseLandmarkType, PoseLandmarkType)> connections = [
        (PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder),
        (PoseLandmarkType.leftShoulder, PoseLandmarkType.leftHip),
        (PoseLandmarkType.rightShoulder, PoseLandmarkType.rightHip),
        (PoseLandmarkType.leftHip, PoseLandmarkType.rightHip),
        (PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow),
        (PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist),
        (PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow),
        (PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist),
        (PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee),
        (PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle),
        (PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee),
        (PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle),
      ];

      for (final (startType, endType) in connections) {
        if (scaledPoints.containsKey(startType) && scaledPoints.containsKey(endType)) {
          canvas.drawLine(scaledPoints[startType]!, scaledPoints[endType]!, linePaint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant material.CustomPainter oldDelegate) => true;
}

class PerformanceTracker {
  final Battery _battery = Battery();
  final Map<SmoothingMode, List<double>> _frameTimes = {
    SmoothingMode.none: [],
    SmoothingMode.exponential: [],
  };
  final Map<SmoothingMode, List<double>> _fpsValues = {
    SmoothingMode.none: [],
    SmoothingMode.exponential: [],
  };
  final Map<SmoothingMode, List<double>> _jitterValues = {
    SmoothingMode.none: [],
    SmoothingMode.exponential: [],
  };
  final Map<SmoothingMode, List<double>> _latencyValues = {
    SmoothingMode.none: [],
    SmoothingMode.exponential: [],
  };
  double? lastFrameTime;
  double? lastFps;
  double? lastJitter;
  double? lastLatency;
  late File _logFile;

  PerformanceTracker() {
    _initializeLogFile();
    material.FlutterError.onError = (details) => log("❌ Ошибка Flutter: ${details.exception}");
  }

  Future<void> _initializeLogFile() async {
    final directory = await getTemporaryDirectory();
    _logFile = File('${directory.path}/pose_detection_log.txt');
    await _logFile.writeAsString('Лог детектора поз\n');
  }

  Future<void> log(String message) async {
    final timestamp = DateTime.now().toIso8601String();
    await _logFile.writeAsString('[$timestamp] $message\n', mode: FileMode.append);
    print(message);
  }

  void recordFrameTime(
      double elapsedMs,
      double fps,
      double latency,
      Map<PoseLandmarkType, Vector2> velocities,
      SmoothingMode mode) {
    _frameTimes[mode]!.add(elapsedMs);
    _fpsValues[mode]!.add(fps);
    _latencyValues[mode]!.add(latency);

    // Calculate jitter as average velocity magnitude across landmarks
    double jitter = 0.0;
    if (velocities.isNotEmpty) {
      final velocityMagnitudes = velocities.values
          .map((v) => math.sqrt(v.x * v.x + v.y * v.y))
          .toList();
      jitter = velocityMagnitudes.reduce((a, b) => a + b) / velocityMagnitudes.length;
    }
    _jitterValues[mode]!.add(jitter);

    lastFrameTime = elapsedMs;
    lastFps = fps;
    lastJitter = jitter;
    lastLatency = latency;

    log("🖼️ Время кадра: ${elapsedMs.toStringAsFixed(2)} мс, FPS: ${fps.toStringAsFixed(2)}, "
        "Jitter: ${jitter.toStringAsFixed(2)} px, Latency: ${latency.toStringAsFixed(2)} мс, Режим: $mode");
  }

  Future<void> logMetrics(SmoothingMode currentMode) async {
    await _logSystemUsage();
    await _logBatteryLevel();
    _logPerformanceSummary(currentMode);
  }

  Future<void> _logSystemUsage() async {
    final totalMemory = SysInfo.getTotalPhysicalMemory();
    final freeMemory = SysInfo.getFreePhysicalMemory();
    final usedMB = (totalMemory - freeMemory) / (1024 * 1024);
    log("🧠 Использовано ОЗУ: ${usedMB.toStringAsFixed(2)} МБ");
  }

  Future<void> _logBatteryLevel() async {
    final batteryLevel = await _battery.batteryLevel;
    log("🔋 Уровень заряда: $batteryLevel%");
  }

  void _logPerformanceSummary(SmoothingMode currentMode) {
    final summary = StringBuffer('📊 Сводка производительности (Режим: $currentMode)\n');
    for (var mode in SmoothingMode.values) {
      final times = _frameTimes[mode]!;
      final fps = _fpsValues[mode]!;
      final jitter = _jitterValues[mode]!;
      final latency = _latencyValues[mode]!;
      if (times.isNotEmpty) {
        final avgTime = times.reduce((a, b) => a + b) / times.length;
        final avgFps = fps.reduce((a, b) => a + b) / fps.length;
        final avgJitter = jitter.reduce((a, b) => a + b) / jitter.length;
        final avgLatency = latency.reduce((a, b) => a + b) / latency.length;
        summary.writeln(
            '${mode.toString().split('.').last}: Среднее время: ${avgTime.toStringAsFixed(2)} мс, '
                'Средний FPS: ${avgFps.toStringAsFixed(2)}, '
                'Средний Jitter: ${avgJitter.toStringAsFixed(2)} px, '
                'Средняя Latency: ${avgLatency.toStringAsFixed(2)} мс');
        times.clear();
        fps.clear();
        jitter.clear();
        latency.clear();
      }
    }
    log(summary.toString());
  }

  void dispose() {}
}