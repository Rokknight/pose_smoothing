# pose_smoothing
Flutter app for pose tracking with exponential smoothing

Pose Detection App
A Flutter application for real-time human pose detection using the device's camera and Google ML Kit Pose Detection.
Features

Real-time pose detection with front/back camera support
Configurable settings: model accuracy, resolution, smoothing mode
Exponential smoothing for stable landmark tracking
Performance monitoring (FPS, jitter, latency, battery, memory)
Debug overlay with detailed metrics

Requirements

Flutter 3.0+
Dart 3.0+
Dependencies: google_mlkit_pose_detection, camera, battery_plus, permission_handler, system_info2, path_provider, vector_math

Usage

Ensure camera permissions are granted.
Launch the app to start real-time pose detection.
Use the app bar to:
Toggle between base/accurate ML models
Switch cameras
Adjust settings (resolution, smoothing, debug display)

Performance Tracking

Logs frame time, FPS, jitter, latency, and system usage (RAM, battery)
Data saved to a temporary log file (pose_detection_log.txt)

License
MIT

-------------------------------------------------------------------------------------------------------------------------
Приложение для детекции поз (Русский)
Мобильное приложение на Flutter для обнаружения поз человека в реальном времени с использованием камеры устройства и Google ML Kit Pose Detection.
Возможности

Обнаружение поз в реальном времени с поддержкой фронтальной и задней камер
Настраиваемые параметры: точность модели, разрешение, режим сглаживания
Экспоненциальное сглаживание для стабильного отслеживания ключевых точек
Мониторинг производительности (FPS, джиттер, задержка, батарея, память)
Отладочная информация с подробными метриками

Требования

Flutter 3.0+
Dart 3.0+
Зависимости: google_mlkit_pose_detection, camera, battery_plus, permission_handler, system_info2, path_provider, vector_math

Использование

Убедитесь, что предоставлены разрешения для камеры.
Запустите приложение для начала детекции поз в реальном времени.
Используйте панель приложения для:
Переключения между базовой и точной моделями ML
Смены камеры
Настройки параметров (разрешение, сглаживание, отображение отладки)

Мониторинг производительности

Логирование времени кадра, FPS, джиттера, задержки и использования системы (ОЗУ, батарея)
Данные сохраняются в временный лог-файл (pose_detection_log.txt)

Лицензия
MIT

-------------------------------------------------------------------------------------------------------------------------
Поза анықтау қолданбасы (Қазақша)
Flutter негізіндегі мобильді қолданба, құрылғының камерасы мен Google ML Kit Pose Detection арқылы адам позаларын нақты уақытта анықтауға арналған.
Мүмкіндіктер

Алдыңғы және артқы камераларды қолдай отырып, нақты уақытта поза анықтау
Реттелетін параметрлер: модель дәлдігі, ажыратымдылық, тегістеу режимі
Негізгі нүктелерді тұрақты бақылау үшін экспоненциалды тегістеу
Өнімділікті бақылау (FPS, джиттер, кідіріс, батарея, жад)
Толық метрикалары бар отладтау ақпараты

Талаптар

Flutter 3.0+
Dart 3.0+
Тәуелділіктер: google_mlkit_pose_detection, camera, battery_plus, permission_handler, system_info2, path_provider, vector_math

Пайдалану

Камераға рұқсат берілгеніне көз жеткізіңіз.
Нақты уақытта поза анықтауды бастау үшін қолданбаны іске қосыңыз.
Қолданба панелін пайдаланып:
Негізгі және дәл ML модельдері арасында ауысыңыз
Камераны ауыстырыңыз
Параметрлерді реттеңіз (ажыратымдылық, тегістеу, отладтауды көрсету)



Өнімділікті бақылау

Кадр уақыты, FPS, джиттер, кідіріс және жүйе ресурстары (ЖЖҚ, батарея) туралы лог жүргізу
Деректер уақытша лог файлына сақталады (pose_detection_log.txt)

Лицензия
MIT

