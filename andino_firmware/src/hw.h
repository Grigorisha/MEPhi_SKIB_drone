#pragma once

namespace andino {

/// @brief Распиновка Arduino UNO робота Vindicator2.
///
/// Соглашение о знаках (проверено на стенде 26.09.2026, робот приподнят):
///   положительный ШИМ мотора    — гусеница едет ВПЕРЁД;
///   рост счётчика энкодера      — гусеница едет ВПЕРЁД.
///
/// На каждом борту мотор и энкодер обязаны считать в одну сторону. Иначе PID
/// получает положительную обратную связь: ошибка растёт, он добавляет газ, и
/// гусеница уходит в полный ход на любую ненулевую команду. Так и было до этой
/// правки на левом борту — энкодер считал вперёд, а мотор по «положительной»
/// команде ехал назад. Прежняя инверсия знака в ROS это маскировала.
///
/// Пины физически подключены так же, как раньше, — поменялись только подписи.
/// Если моторы или энкодеры перепаяют, проверять тестом
/// mephi_hw_tests/wheels_check.sh и править пары пинов здесь, а не знаки в ROS.
struct Hw {
  /// @brief Энкодер левого мотора канал A (digital pin 2). Считает вперёд как есть.
  static constexpr int kLeftEncoderChannelAGpioPin{2};
  /// @brief Энкодер левого мотора канал B (digital pin 3)
  static constexpr int kLeftEncoderChannelBGpioPin{3};

  /// @brief Энкодер правого мотора канал A (analog pin A3)
  /// @note Каналы A/B переставлены (A3/A2), чтобы правый энкодер тоже считал вперёд.
  static constexpr int kRightEncoderChannelAGpioPin{17};
  /// @brief Энкодер правого мотора канал B (analog pin A2)
  static constexpr int kRightEncoderChannelBGpioPin{16};

  /// @brief Левый мотор IN1 (digital pin 6) — ШИМ на нём везёт гусеницу вперёд
  static constexpr int kLeftMotorForwardGpioPin{6};
  /// @brief Левый мотор IN2 (digital pin 10) — назад
  static constexpr int kLeftMotorBackwardGpioPin{10};
  /// @brief
  /// @note
  /// Левый мотор ENA (digital pin 13)
  static constexpr int kLeftMotorEnableGpioPin{13};

  /// @brief Правый мотор IN3 (digital pin 5) — ШИМ на нём везёт гусеницу вперёд
  static constexpr int kRightMotorForwardGpioPin{5};
  /// @brief Правый мотор IN4 (digital pin 9) — назад
  static constexpr int kRightMotorBackwardGpioPin{9};
  /// @brief
  /// @note
  /// Правый мотор ENB (digital pin 12)
  static constexpr int kRightMotorEnableGpioPin{12};

  /// @brief IMU I2C SCL (analog pin A5).
  static constexpr int kImuI2cSclPin{19};
  /// @brief IMU I2C SDA (analog pin A4)
  static constexpr int kImuI2cSdaPin{18};
};

}
