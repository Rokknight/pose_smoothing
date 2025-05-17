import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:system_info2/system_info2.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_isolate/flutter_isolate.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await _requestCameraPermission();
  final cameras = await availableCameras();
  runApp(MyApp(cameras: cameras));
}

Future<void> _requestCameraPermission() async {
  var status = await Permission.camera.status;
  if (!status.isGranted) {
    await Permission.camera.request();
  }
}

class MyApp extends StatelessWidget {
  final List<CameraDescription> cameras;
  const MyApp({Key? key, required this.cameras}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      debugShowCheckedModeBanner: false,
      showPerformanceOverlay: true,
      home: PoseDetectionScreen(cameras: cameras),
    );
  }
}

class PoseDetectionScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const PoseDetectionScreen({Key? key, required this.cameras}) : super(key: key);

  @override
  _PoseDetectionScreenState createState() => _PoseDetectionScreenState();
}

class _PoseDetectionScreenState extends State<PoseDetectionScreen> {
  late CameraController _controller;
  late PoseDetector _poseDetector;
  late PerformanceTracker _performanceTracker;
  bool _isProcessing = false;
  List<Pose> _poses = [];
  String _debugInfo = 'Initializing...';
  bool _useAccurateModel = false;
  ResolutionPreset _resolution = ResolutionPreset.low;
  bool _showDebugFrame = true;
  int _cameraIndex = 0;
  late File _logFile;
  Timer? _logTimer;

  // Метод для получения yOffset в зависимости от разрешения
  double get yOffset {
    switch (_resolution) {
      case ResolutionPreset.low:
        return -150.0;
      case ResolutionPreset.high:
        return -70.0;
      default:
        return -70.0;
    }
  }

  @override
  void initState() {
    super.initState();
    _initializeLogFile();
    _initializeCamera();
    _initializePoseDetector();
    _performanceTracker = PerformanceTracker(_logToFile);
    _logTimer = Timer.periodic(Duration(seconds: 30), (timer) {
      _performanceTracker.logMetrics();
    });
  }

  Future<void> _initializeLogFile() async {
    final directory = await getTemporaryDirectory();
    _logFile = File('${directory.path}/pose_detection_log.txt');
    await _logFile.writeAsString('Pose Detection Log\n');
  }

  Future<void> _logToFile(String message) async {
    final timestamp = DateTime.now().toIso8601String();
    await _logFile.writeAsString('[$timestamp] $message\n', mode: FileMode.append);
  }

  Future<void> _initializeCamera() async {
    try {
      _controller = CameraController(widget.cameras[_cameraIndex], _resolution);
      await _controller.initialize();
      if (!mounted) return;
      await _controller.startImageStream(_processCameraImage);
      await _logToFile('Camera initialized: ${_controller.description.name}');
      setState(() => _debugInfo = 'Camera initialized');
    } catch (e) {
      await _logToFile('Camera error: $e');
      setState(() => _debugInfo = 'Camera error: $e');
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

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isProcessing) return;

    _isProcessing = true;
    final stopwatch = Stopwatch()..start();

    try {
      final inputImage = await compute(_convertCameraImage, {
        'image': image,
        'camera': widget.cameras[_cameraIndex],
      });

      final poses = await _poseDetector.processImage(inputImage);
      await _logToFile('Processed frame, poses detected: ${poses.length}');

      stopwatch.stop();
      final frameTime = stopwatch.elapsedMilliseconds.toDouble();
      final fps = frameTime > 0 ? 1000.0 / frameTime : 0.0;

      setState(() {
        _poses = poses;
        _debugInfo = 'Poses: ${poses.length}, Frame time: ${frameTime.toStringAsFixed(2)} ms, FPS: ${fps.toStringAsFixed(2)}, yOffset: $yOffset';
      });

      _performanceTracker.recordFrameTime(frameTime);
    } catch (e) {
      await _logToFile('Error processing frame: $e');
      setState(() => _debugInfo = 'Error: $e');
    }

    _isProcessing = false;
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
    setState(() {});
  }

  Future<void> _updateSettings({
    bool? useAccurateModel,
    ResolutionPreset? resolution,
    bool? showDebugFrame,
  }) async {
    if (useAccurateModel != null) {
      _useAccurateModel = useAccurateModel;
      _poseDetector.close();
      _initializePoseDetector();
      await _logToFile('Pose detector model changed to: ${_useAccurateModel ? "accurate" : "base"}');
    }
    if (resolution != null) {
      _resolution = resolution;
      await _controller.dispose();
      await _initializeCamera();
      await _logToFile('Camera resolution changed to: $resolution');
    }
    if (showDebugFrame != null) {
      _showDebugFrame = showDebugFrame;
      await _logToFile('Debug frame visibility changed to: $showDebugFrame');
    }
    setState(() {});
  }

  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Настройки'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                title: const Text('Точная модель'),
                value: _useAccurateModel,
                onChanged: (val) {
                  Navigator.pop(context);
                  _updateSettings(useAccurateModel: val);
                },
              ),
              SwitchListTile(
                title: const Text('Показать отладку'),
                value: _showDebugFrame,
                onChanged: (val) {
                  Navigator.pop(context);
                  _updateSettings(showDebugFrame: val);
                },
              ),
              DropdownButton<ResolutionPreset>(
                value: _resolution,
                items: [ResolutionPreset.low, ResolutionPreset.high].map((res) {
                  return DropdownMenuItem(
                    value: res,
                    child: Text(res.toString().split('.').last),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) {
                    Navigator.pop(context);
                    _updateSettings(resolution: val);
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _poseDetector.close();
    _logTimer?.cancel();
    _performanceTracker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_controller.value.isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final size = MediaQuery.of(context).size;
    final frameWidth = size.width;
    const frameOffset = 0.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pose Detector'),
        actions: [
          IconButton(
            icon: Icon(Icons.flash_on, color: _useAccurateModel ? Colors.grey : Colors.white),
            onPressed: () {
              _updateSettings(useAccurateModel: false);
            },
          ),
          IconButton(
            icon: Icon(Icons.center_focus_strong, color: _useAccurateModel ? Colors.white : Colors.grey),
            onPressed: () {
              _updateSettings(useAccurateModel: true);
            },
          ),
          IconButton(icon: const Icon(Icons.cameraswitch), onPressed: _switchCamera),
          IconButton(icon: const Icon(Icons.settings), onPressed: _showSettingsDialog),
        ],
      ),
      body: Stack(
        children: [
          CameraPreview(_controller),
          Positioned(
            right: frameOffset,
            top: 10,
            bottom: 10,
            child: Container(
              width: frameWidth,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.green, width: 2),
              ),
              child: CustomPaint(
                painter: SkeletonPainter(
                  poses: _poses,
                  imageSize: Size(
                    _controller.value.previewSize!.height,
                    _controller.value.previewSize!.width,
                  ),
                  frameSize: size,
                  yOffset: yOffset,
                ),
                child: Container(),
              ),
            ),
          ),
          if (_showDebugFrame)
            Positioned(
              bottom: 10,
              left: 10,
              child: Container(
                color: Colors.black54,
                padding: const EdgeInsets.all(8),
                child: Text(
                  _debugInfo,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class SkeletonPainter extends CustomPainter {
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
  void paint(Canvas canvas, Size size) {
    final pointPaint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.fill;

    final linePaint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    for (final pose in poses) {
      final landmarks = pose.landmarks;
      final Map<PoseLandmarkType, Offset> scaledPoints = {};

      landmarks.forEach((type, landmark) {
        final scaleX = frameSize.width / imageSize.width;
        final scaleY = frameSize.height / imageSize.height;
        final scale = math.min(scaleX, scaleY);

        final dx = (frameSize.width - imageSize.width * scale) / 2;
        final dy = (frameSize.height - imageSize.height * scale) / 2 + yOffset;

        final point = Offset(
          landmark.x * scale + dx,
          landmark.y * scale + dy,
        );
        scaledPoints[type] = point;
      });

      scaledPoints.values.forEach((point) {
        canvas.drawCircle(point, 5, pointPaint);
      });

      final connections = [
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
          canvas.drawLine(
            scaledPoints[startType]!,
            scaledPoints[endType]!,
            linePaint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class PerformanceTracker {
  final Battery _battery = Battery();
  final List<double> _frameTimes = [];
  final List<double> _fpsValues = [];
  final Function(String) _logCallback;

  PerformanceTracker(this._logCallback) {
    FlutterError.onError = (FlutterErrorDetails details) {
      print("❌ Flutter Error: ${details.exception}");
      _logCallback("❌ Flutter Error: ${details.exception}");
    };
  }

  void recordFrameTime(double elapsedMs) {
    _frameTimes.add(elapsedMs);
    final fps = 1000.0 / elapsedMs;
    _fpsValues.add(fps);
    print("🖼️ Frame time: ${elapsedMs.toStringAsFixed(2)} ms, FPS: ${fps.toStringAsFixed(2)}");
  }

  double get lastFps => _fpsValues.isNotEmpty ? _fpsValues.last : 0.0;

  Future<void> logMetrics() async {
    await _logSystemUsage();
    await _logBatteryLevel();
    _logAverageFPS();
    _logAverageInferenceTime();
  }

  Future<void> _logSystemUsage() async {
    int totalMemory = SysInfo.getTotalPhysicalMemory();
    int freeMemory = SysInfo.getFreePhysicalMemory();
    double usedMB = (totalMemory - freeMemory) / (1024 * 1024);
    String log = "🧠 RAM used: ${usedMB.toStringAsFixed(2)} MB";
    print(log);
    await _logCallback(log);
  }

  Future<void> _logBatteryLevel() async {
    int batteryLevel = await _battery.batteryLevel;
    String log = "🔋 Battery: $batteryLevel%";
    print(log);
    await _logCallback(log);
  }

  void _logAverageFPS() {
    if (_fpsValues.isEmpty) return;
    double avgFps = _fpsValues.reduce((a, b) => a + b) / _fpsValues.length;
    String log = "🎯 Avg FPS: ${avgFps.toStringAsFixed(2)}";
    print(log);
    _logCallback(log);
    _fpsValues.clear();
  }

  void _logAverageInferenceTime() {
    if (_frameTimes.isEmpty) return;
    double avgTime = _frameTimes.reduce((a, b) => a + b) / _frameTimes.length;
    String log = "📊 Avg inference time: ${avgTime.toStringAsFixed(2)} ms";
    print(log);
    _logCallback(log);
    _frameTimes.clear();
  }

  void dispose() {}
}