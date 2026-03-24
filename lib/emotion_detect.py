#!/usr/bin/env python3
"""
Offline facial emotion detection for claude-vibe-check.
Analyzes a single image and outputs JSON to stdout.

Supports two backends:
  - fer (default, simplest, ~200ms)
  - hsemotion (better accuracy, ~100ms, needs hsemotion-onnx)

Usage:
  python3 emotion_detect.py <image_path> [--backend fer|hsemotion]
"""

import sys
import json
import os


def analyze_fer(image_path):
    """Analyze emotions using FER library (Keras CNN + OpenCV Haar cascade)."""
    import cv2
    try:
        from fer import FER
    except ImportError:
        from fer.fer import FER

    img = cv2.imread(image_path)
    if img is None:
        return {"error": f"Could not read image: {image_path}"}

    detector = FER(mtcnn=False)
    results = detector.detect_emotions(img)

    if not results:
        return {"error": "No face detected", "suggestion": "Make sure your face is visible and well-lit"}

    faces = []
    for r in results:
        dominant = max(r["emotions"], key=r["emotions"].get)
        faces.append({
            "dominant_emotion": dominant,
            "confidence": round(r["emotions"][dominant], 3),
            "all_emotions": {k: round(v, 3) for k, v in r["emotions"].items()},
        })
    return {"faces": faces, "backend": "fer"}


def analyze_hsemotion(image_path):
    """Analyze emotions using HSEmotion ONNX (EfficientNet, trained on AffectNet)."""
    import cv2
    from hsemotion_onnx.facial_emotions import HSEmotionRecognizer

    img = cv2.imread(image_path)
    if img is None:
        return {"error": f"Could not read image: {image_path}"}

    # Detect face with OpenCV Haar cascade
    face_cascade = cv2.CascadeClassifier(
        cv2.data.haarcascades + "haarcascade_frontalface_default.xml"
    )
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    faces_rects = face_cascade.detectMultiScale(gray, 1.1, 5, minSize=(48, 48))

    if len(faces_rects) == 0:
        return {"error": "No face detected", "suggestion": "Make sure your face is visible and well-lit"}

    recognizer = HSEmotionRecognizer(model_name="enet_b0_8_best_afew")

    faces = []
    for x, y, w, h in faces_rects:
        face_img = img[y : y + h, x : x + w]
        emotion, scores = recognizer.predict_emotions(face_img, logits=True)
        faces.append({
            "dominant_emotion": emotion,
            "all_emotions": {k: round(float(v), 3) for k, v in zip(
                ["anger", "contempt", "disgust", "fear", "happiness", "neutral", "sadness", "surprise"],
                scores,
            )},
        })
    return {"faces": faces, "backend": "hsemotion"}


def detect_backend():
    """Auto-detect the best available backend."""
    try:
        from hsemotion_onnx.facial_emotions import HSEmotionRecognizer
        return "hsemotion"
    except ImportError:
        pass

    try:
        from fer import FER
        return "fer"
    except ImportError:
        try:
            from fer.fer import FER
            return "fer"
        except ImportError:
            pass

    return None


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: emotion_detect.py <image_path> [--backend fer|hsemotion]"}))
        sys.exit(1)

    image_path = sys.argv[1]

    # Parse --backend flag
    backend = None
    for i, arg in enumerate(sys.argv[2:], 2):
        if arg == "--backend" and i + 1 < len(sys.argv):
            backend = sys.argv[i + 1]

    if not os.path.isfile(image_path):
        print(json.dumps({"error": f"File not found: {image_path}"}))
        sys.exit(1)

    if backend is None:
        backend = detect_backend()

    if backend is None:
        print(json.dumps({
            "error": "No emotion detection backend installed",
            "install": "pip install fer opencv-python-headless  # or: pip install hsemotion-onnx opencv-python-headless",
        }))
        sys.exit(1)

    # Suppress TensorFlow/ONNX warnings
    os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")

    try:
        if backend == "hsemotion":
            result = analyze_hsemotion(image_path)
        else:
            result = analyze_fer(image_path)
    except Exception as e:
        result = {"error": str(e)}

    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
