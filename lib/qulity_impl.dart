import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:image/image.dart' as img;

class UniquePerson {
  String imagePath;
  final int id;
  double imageQuality;
  DateTime lastUpdated;
  Face face;

  UniquePerson({
    required this.imagePath,
    required this.id,
    required this.imageQuality,
    required this.face,
  }) : lastUpdated = DateTime.now();
}

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } on CameraException catch (e) {
    debugPrint('Error initializing cameras: $e');
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Face Detection App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const FaceDetectionPage(),
    );
  }
}

class FaceDetectionPage extends StatefulWidget {
  const FaceDetectionPage({super.key});

  @override
  State<FaceDetectionPage> createState() => _FaceDetectionPageState();
}

class _FaceDetectionPageState extends State<FaceDetectionPage> {
  CameraController? _controller;
  bool _isFrontCamera = false;
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableLandmarks: true,
      enableClassification: true,
      enableTracking: true,
      minFaceSize: 0.15,
      performanceMode: FaceDetectorMode.fast,
    ),
  );

  bool _isBusy = false;
  bool _isPermissionGranted = false;
  List<Face> _faces = [];
  final Map<int, UniquePerson> _uniquePersons = {};
  final double _similarityThreshold = 0.15;
  int _frameSkipCount = 0;
  static const int _frameSkipTarget = 5;

  double _calculateFaceQuality(Face face, img.Image image) {
    double quality = 0.0;

    final faceArea = face.boundingBox.width * face.boundingBox.height;
    final imageArea = image.width * image.height;
    quality += (faceArea / imageArea) * 0.4;

    final yaw = (face.headEulerAngleY ?? 90).abs();
    final pitch = (face.headEulerAngleX ?? 90).abs();
    if (yaw < 15 && pitch < 15)
      quality += 0.3;
    else if (yaw < 30 && pitch < 30) quality += 0.15;

    if (face.landmarks.isNotEmpty) quality += 0.3;

    return quality;
  }

  bool _isSimilarFace(Face newFace, Face existingFace) {
    if (newFace.landmarks.isEmpty || existingFace.landmarks.isEmpty)
      return false;

    final newNose = newFace.landmarks[FaceLandmarkType.noseBase];
    final existingNose = existingFace.landmarks[FaceLandmarkType.noseBase];

    if (newNose == null || existingNose == null) return false;

    double newNoseX = newNose.position.x / newFace.boundingBox.width;
    double newNoseY = newNose.position.y / newFace.boundingBox.height;
    double existingNoseX =
        existingNose.position.x / existingFace.boundingBox.width;
    double existingNoseY =
        existingNose.position.y / existingFace.boundingBox.height;

    double positionDiff = sqrt(
        pow(newNoseX - existingNoseX, 2) + pow(newNoseY - existingNoseY, 2));

    if (positionDiff > _similarityThreshold * 2) return false;

    final angleYDiff = (newFace.headEulerAngleY ?? 0.0) -
        (existingFace.headEulerAngleY ?? 0.0);
    final angleZDiff = (newFace.headEulerAngleZ ?? 0.0) -
        (existingFace.headEulerAngleZ ?? 0.0);

    return positionDiff < _similarityThreshold &&
        angleYDiff.abs() < 15.0 &&
        angleZDiff.abs() < 15.0;
  }

  Future<void> _processImage(CameraImage image) async {
    if (!mounted || _isBusy) return;

    _frameSkipCount++;
    if (_frameSkipCount < _frameSkipTarget) return;
    _frameSkipCount = 0;

    _isBusy = true;
    try {
      final XFile file = await _controller!.takePicture();
      final inputImage = InputImage.fromFilePath(file.path);
      final faces = await _faceDetector.processImage(inputImage);

      if (mounted && faces.isNotEmpty) {
        faces.sort((a, b) => (b.boundingBox.width * b.boundingBox.height)
            .compareTo(a.boundingBox.width * a.boundingBox.height));

        await _processFaceBatch(file.path, faces);

        setState(() {
          _faces = faces;
        });
      }

      await File(file.path).delete();
    } catch (e) {
      debugPrint('Error processing image: $e');
    } finally {
      _isBusy = false;
      if (mounted && _controller != null) {
        await Future.delayed(const Duration(milliseconds: 100));
        await _startImageStream();
      }
    }
  }

  Future<void> _processFaceBatch(String sourcePath, List<Face> faces) async {
    final File sourceFile = File(sourcePath);
    final Uint8List imageBytes = await sourceFile.readAsBytes();
    final img.Image? originalImage = img.decodeImage(imageBytes);

    if (originalImage == null) return;

    for (var face in faces) {
      if (face.boundingBox.width < 40 || face.boundingBox.height < 40) continue;

      final double newQuality = _calculateFaceQuality(face, originalImage);
      final int faceId =
          face.trackingId ?? DateTime.now().millisecondsSinceEpoch;

      bool isNewPerson = true;
      for (var existingPerson in _uniquePersons.values) {
        if (_isSimilarFace(face, existingPerson.face)) {
          isNewPerson = false;
          if (newQuality > existingPerson.imageQuality) {
            await _saveFaceImage(originalImage, face, faceId, newQuality,
                update: true);
          }
          break;
        }
      }

      if (isNewPerson) {
        await _saveFaceImage(originalImage, face, faceId, newQuality);
      }
    }
  }

  Future<void> _saveFaceImage(
      img.Image originalImage, Face face, int faceId, double quality,
      {bool update = false}) async {
    try {
      final rect = face.boundingBox;
      final int padding = 40;

      final img.Image croppedFace = img.copyCrop(
        originalImage,
        x: (rect.left - padding).round().clamp(0, originalImage.width - 1),
        y: (rect.top - padding).round().clamp(0, originalImage.height - 1),
        width: (rect.width + 2 * padding).round().clamp(1, originalImage.width),
        height:
            (rect.height + 2 * padding).round().clamp(1, originalImage.height),
      );

      final directory = await getApplicationDocumentsDirectory();
      final String fileName =
          'face_${faceId}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final String targetPath = path.join(directory.path, fileName);

      final Uint8List encodedImage =
          Uint8List.fromList(img.encodeJpg(croppedFace, quality: 85));
      await File(targetPath).writeAsBytes(encodedImage);

      if (mounted) {
        setState(() {
          if (update && _uniquePersons.containsKey(faceId)) {
            File(_uniquePersons[faceId]!.imagePath).delete();
            _uniquePersons[faceId]!.imagePath = targetPath;
            _uniquePersons[faceId]!.imageQuality = quality;
            _uniquePersons[faceId]!.lastUpdated = DateTime.now();
            _uniquePersons[faceId]!.face = face;
          } else {
            _uniquePersons[faceId] = UniquePerson(
              imagePath: targetPath,
              id: faceId,
              imageQuality: quality,
              face: face,
            );
          }
        });
      }
    } catch (e) {
      debugPrint('Error saving face image: $e');
    }
  }

  Future<void> _startImageStream() async {
    if (_controller == null) return;
    try {
      await _controller!.startImageStream((CameraImage image) {
        if (!_isBusy) {
          _processImage(image);
        }
      });
    } catch (e) {
      debugPrint('Error starting image stream: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _requestCameraPermission();
  }

  @override
  void dispose() {
    _stopImageStream();
    _controller?.dispose();
    _faceDetector.close();
    _clearImages();
    super.dispose();
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    setState(() {
      _isPermissionGranted = status == PermissionStatus.granted;
    });
    if (_isPermissionGranted) {
      await _initializeCamera();
    }
  }

  void _stopImageStream() {
    try {
      _controller?.stopImageStream();
    } catch (e) {
      debugPrint('Error stopping image stream: $e');
    }
  }

  void _toggleCamera() async {
    setState(() {
      _isFrontCamera = !_isFrontCamera;
    });
    await _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) return;

    final camera = cameras.firstWhere(
      (camera) =>
          camera.lensDirection ==
          (_isFrontCamera
              ? CameraLensDirection.front
              : CameraLensDirection.back),
      orElse: () => cameras.first,
    );

    _stopImageStream();
    await _controller?.dispose();

    _controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.yuv420
          : ImageFormatGroup.bgra8888,
    );

    try {
      await _controller!.initialize();
      if (mounted) {
        setState(() {});
        await _startImageStream();
      }
    } catch (e) {
      debugPrint('Error initializing camera: $e');
    }
  }

  void _clearImages() async {
    for (final person in _uniquePersons.values) {
      try {
        await File(person.imagePath).delete();
      } catch (e) {
        debugPrint('Error deleting file: $e');
      }
    }
    setState(() {
      _uniquePersons.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isPermissionGranted) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('Camera permission not granted'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _requestCameraPermission,
                child: const Text('Request Permission'),
              ),
            ],
          ),
        ),
      );
    }

    if (_controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Face Detection'),
        actions: [
          IconButton(
            icon: Icon(_isFrontCamera ? Icons.camera_rear : Icons.camera_front),
            onPressed: _toggleCamera,
            tooltip: 'Switch Camera',
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: _clearImages,
            tooltip: 'Clear Images',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 2,
            child: Transform.rotate(
              angle: 90 * pi / 180,
              child: Center(
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: CameraPreview(_controller!),
                ),
              ),
            ),
          ),
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 4,
                mainAxisSpacing: 4,
              ),
              itemCount: _uniquePersons.length,
              itemBuilder: (context, index) {
                final person = _uniquePersons.values.elementAt(index);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8.0),
                      child: Image.file(
                        File(person.imagePath),
                        fit: BoxFit.cover,
                      ),
                    ),
                    Positioned(
                      bottom: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'Q: ${(person.imageQuality * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
