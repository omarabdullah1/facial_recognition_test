// import 'dart:math';
// import 'dart:typed_data';
// import 'package:flutter/material.dart';
// import 'package:camera/camera.dart';
// import 'package:flutter/services.dart';
// import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
// import 'package:permission_handler/permission_handler.dart';
// import 'dart:io';
// import 'package:path_provider/path_provider.dart';
// import 'package:path/path.dart' as path;
// import 'package:image/image.dart' as img;

// List<CameraDescription> cameras = [];

// Future<void> main() async {
//   WidgetsFlutterBinding.ensureInitialized();
//   try {
//     cameras = await availableCameras();
//   } on CameraException catch (e) {
//     debugPrint('Error initializing cameras: $e');
//   }
//   runApp(const MyApp());
// }

// class MyApp extends StatelessWidget {
//   const MyApp({super.key});

//   @override
//   Widget build(BuildContext context) {
//     return MaterialApp(
//       title: 'Face Detection App',
//       theme: ThemeData(
//         colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
//         useMaterial3: true,
//       ),
//       home: const FaceDetectionPage(),
//     );
//   }
// }

// class FaceDetectionPage extends StatefulWidget {
//   const FaceDetectionPage({super.key});

//   @override
//   State<FaceDetectionPage> createState() => _FaceDetectionPageState();
// }

// class _FaceDetectionPageState extends State<FaceDetectionPage> {
//   CameraController? _controller;
//   bool _isFrontCamera = false;
//   final FaceDetector _faceDetector = FaceDetector(
//     options: FaceDetectorOptions(
//       enableLandmarks: true,
//       enableClassification: true,
//       enableTracking: true,
//       minFaceSize: 0.15, // Increased minimum face size
//       performanceMode: FaceDetectorMode.fast, // Changed to fast mode
//     ),
//   );
  
//   bool _isBusy = false;
//   bool _isPermissionGranted = false;
//   List<Face> _faces = [];
//   final List<String> _capturedFaceImages = [];
//   final Map<int, Face> _uniqueFaces = {};
//   final double _similarityThreshold = 0.15; // Increased threshold
//   int _frameSkipCount = 0;
//   static const int _frameSkipTarget = 3; // Process every 3rd frame

//   // Optimized face similarity comparison
//   bool _isSimilarFace(Face newFace, Face existingFace) {
//     if (newFace.landmarks.isEmpty || existingFace.landmarks.isEmpty) return false;

//     final newNose = newFace.landmarks[FaceLandmarkType.noseBase];
//     final existingNose = existingFace.landmarks[FaceLandmarkType.noseBase];
    
//     if (newNose == null || existingNose == null) return false;

//     // Quick check using nose position and face size
//     double newNoseX = newNose.position.x / newFace.boundingBox.width;
//     double newNoseY = newNose.position.y / newFace.boundingBox.height;
//     double existingNoseX = existingNose.position.x / existingFace.boundingBox.width;
//     double existingNoseY = existingNose.position.y / existingFace.boundingBox.height;

//     double positionDiff = sqrt(pow(newNoseX - existingNoseX, 2) + pow(newNoseY - existingNoseY, 2));
    
//     // Quick rejection if positions are too different
//     if (positionDiff > _similarityThreshold * 2) return false;

//     // Check head angles only if position is similar
//     final angleYDiff = (newFace.headEulerAngleY ?? 0.0) - (existingFace.headEulerAngleY ?? 0.0);
//     final angleZDiff = (newFace.headEulerAngleZ ?? 0.0) - (existingFace.headEulerAngleZ ?? 0.0);

//     return positionDiff < _similarityThreshold && 
//            angleYDiff.abs() < 15.0 && 
//            angleZDiff.abs() < 15.0;
//   }

//   // Optimized image processing
//   Future<void> _processImage(CameraImage image) async {
//     if (!mounted || _isBusy) return;

//     // Frame skipping for performance
//     _frameSkipCount++;
//     if (_frameSkipCount < _frameSkipTarget) return;
//     _frameSkipCount = 0;

//     _isBusy = true;
//     try {
//       final XFile file = await _controller!.takePicture();
//       final inputImage = InputImage.fromFilePath(file.path);
      
//       // Process image in isolate or background
//       final faces = await _faceDetector.processImage(inputImage);
      
//       if (mounted && faces.isNotEmpty) {
//         // Sort faces by size for efficiency
//         faces.sort((a, b) => (b.boundingBox.width * b.boundingBox.height)
//             .compareTo(a.boundingBox.width * a.boundingBox.height));

//         // Batch process faces
//         await _processFaceBatch(file.path, faces);
        
//         setState(() {
//           _faces = faces;
//         });
//       }

//       // Cleanup
//       await File(file.path).delete();
//     } catch (e) {
//       debugPrint('Error processing image: $e');
//     } finally {
//       _isBusy = false;
//       if (mounted && _controller != null) {
//         await Future.delayed(const Duration(milliseconds: 100)); // Reduced delay
//         await _startImageStream();
//       }
//     }
//   }

//   // Batch processing for multiple faces
//   Future<void> _processFaceBatch(String sourcePath, List<Face> faces) async {
//     final File sourceFile = File(sourcePath);
//     final Uint8List imageBytes = await sourceFile.readAsBytes();
//     final img.Image? originalImage = img.decodeImage(imageBytes);

//     if (originalImage == null) return;

//     for (var face in faces) {
//       if (face.boundingBox.width < 40 || face.boundingBox.height < 40) continue;

//       bool isUnique = true;
//       for (var existingFace in _uniqueFaces.values) {
//         if (_isSimilarFace(face, existingFace)) {
//           isUnique = false;
//           break;
//         }
//       }

//       if (isUnique) {
//         await _saveFaceImage(originalImage, face);
//       }
//     }
//   }

//   // Optimized face image saving
//   Future<void> _saveFaceImage(img.Image originalImage, Face face) async {
//     try {
//       final rect = face.boundingBox;
//       final int padding = 40;

//       final int x = (rect.left - padding).round().clamp(0, originalImage.width - 1);
//       final int y = (rect.top - padding).round().clamp(0, originalImage.height - 1);
//       final int w = (rect.width + 2 * padding).round().clamp(1, originalImage.width - x);
//       final int h = (rect.height + 2 * padding).round().clamp(1, originalImage.height - y);

//       final img.Image croppedFace = img.copyCrop(
//         originalImage,
//         x: x,
//         y: y,
//         width: w,
//         height: h,
//       );

//       final directory = await getApplicationDocumentsDirectory();
//       final String fileName = 'face_${DateTime.now().millisecondsSinceEpoch}.jpg';
//       final String targetPath = path.join(directory.path, fileName);

//       // Optimize image quality vs size
//       final Uint8List encodedImage = Uint8List.fromList(img.encodeJpg(croppedFace, quality: 85));
//       await File(targetPath).writeAsBytes(encodedImage);

//       if (mounted) {
//         setState(() {
//           _capturedFaceImages.add(targetPath);
//           _uniqueFaces[face.trackingId ?? DateTime.now().millisecondsSinceEpoch] = face;
//         });
//       }
//     } catch (e) {
//       debugPrint('Error saving face image: $e');
//     }
//   }

//   Future<void> _startImageStream() async {
//     if (_controller == null) return;

//     try {
//       await _controller!.startImageStream((CameraImage image) {
//         if (!_isBusy) {
//           _processImage(image);
//         }
//       });
//     } catch (e) {
//       debugPrint('Error starting image stream: $e');
//     }
//   }

//   @override
//   void initState() {
//     super.initState();
//     _requestCameraPermission();
//   }

//   @override
//   void dispose() {
//     _stopImageStream();
//     _controller?.dispose();
//     _faceDetector.close();
//     // Cleanup saved images
//     for (final path in _capturedFaceImages) {
//       File(path).delete().catchError((e) => debugPrint('Error deleting file: $e'));
//     }
//     super.dispose();
//   }

//   Future<void> _requestCameraPermission() async {
//     final status = await Permission.camera.request();
//     setState(() {
//       _isPermissionGranted = status == PermissionStatus.granted;
//     });

//     if (_isPermissionGranted) {
//       await _initializeCamera();
//     }
//   }

//   void _stopImageStream() {
//     try {
//       _controller?.stopImageStream();
//     } catch (e) {
//       debugPrint('Error stopping image stream: $e');
//     }
//   }

//   void _toggleCamera() async {
//     setState(() {
//       _isFrontCamera = !_isFrontCamera;
//     });
//     await _initializeCamera();
//   }

//   Future<void> _initializeCamera() async {
//     if (cameras.isEmpty) return;

//     final camera = cameras.firstWhere(
//       (camera) => camera.lensDirection == (_isFrontCamera ? CameraLensDirection.front : CameraLensDirection.back),
//       orElse: () => cameras.first,
//     );

//     _stopImageStream();
//     await _controller?.dispose();

//     _controller = CameraController(
//       camera,
//       ResolutionPreset.medium, // Lower resolution for better performance
//       enableAudio: false,
//       imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.yuv420 : ImageFormatGroup.bgra8888,
//     );

//     try {
//       await _controller!.initialize();
//       if (mounted) {
//         setState(() {});
//         await _startImageStream();
//       }
//     } on CameraException catch (e) {
//       debugPrint('Error initializing camera: $e');
//     }
//   }

//   @override
//   Widget build(BuildContext context) {
//     if (!_isPermissionGranted) {
//       return Scaffold(
//         body: Center(
//           child: Column(
//             mainAxisAlignment: MainAxisAlignment.center,
//             children: [
//               const Text('Camera permission not granted'),
//               const SizedBox(height: 16),
//               ElevatedButton(
//                 onPressed: _requestCameraPermission,
//                 child: const Text('Request Permission'),
//               ),
//             ],
//           ),
//         ),
//       );
//     }

//     if (_controller == null || !_controller!.value.isInitialized) {
//       return const Scaffold(
//         body: Center(child: CircularProgressIndicator()),
//       );
//     }

//     return Scaffold(
//       appBar: AppBar(
//         title: const Text('Face Detection'),
//         actions: [
//           IconButton(
//             icon: Icon(_isFrontCamera ? Icons.camera_rear : Icons.camera_front),
//             onPressed: _toggleCamera,
//             tooltip: 'Switch Camera',
//           ),
//         ],
//       ),
//       body: Column(
//         children: [
//           Expanded(
//             flex: 2,
//             child: Transform.rotate(
//               angle: (_isFrontCamera ? 270 : 90) * pi / 180,
//               child: Center(
//                 child: AspectRatio(
//                   aspectRatio: 16.0 / 9.0,
//                   child: CameraPreview(_controller!),
//                 ),
//               ),
//             ),
//           ),
//           Expanded(
//             flex: 1,
//             child: Container(
//               padding: const EdgeInsets.all(8.0),
//               child: Column(
//                 crossAxisAlignment: CrossAxisAlignment.start,
//                 children: [
//                   Text('Detected Faces: ${_faces.length}'),
//                   const SizedBox(height: 8),
//                   Expanded(
//                     child: GridView.builder(
//                       gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
//                         crossAxisCount: 3,
//                         crossAxisSpacing: 4,
//                         mainAxisSpacing: 4,
//                       ),
//                       itemCount: _capturedFaceImages.length,
//                       itemBuilder: (context, index) {
//                         return ClipRRect(
//                           borderRadius: BorderRadius.circular(8),
//                           child: Image.file(
//                             File(_capturedFaceImages[index]),
//                             fit: BoxFit.cover,
//                           ),
//                         );
//                       },
//                     ),
//                   ),
//                 ],
//               ),
//             ),
//           ),
//         ],
//       ),
//     );
//   }
// }