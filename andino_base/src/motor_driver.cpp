// BSD 3-Clause License
//
// Copyright (c) 2023, Ekumen Inc.
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// 3. Neither the name of the copyright holder nor the names of its
//    contributors may be used to endorse or promote products derived from
//    this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#include "andino_base/motor_driver.h"

#include <cstdlib>
#include <iostream>
#include <sstream>

namespace andino_base {
namespace {

bool TryToLibSerialBaudRate(int32_t baud_rate, LibSerial::BaudRate& out_baud_rate) {
  switch (baud_rate) {
    case 9600:
      out_baud_rate = LibSerial::BaudRate::BAUD_9600;
      return true;
    case 19200:
      out_baud_rate = LibSerial::BaudRate::BAUD_19200;
      return true;
    case 38400:
      out_baud_rate = LibSerial::BaudRate::BAUD_38400;
      return true;
    case 57600:
      out_baud_rate = LibSerial::BaudRate::BAUD_57600;
      return true;
    case 115200:
      out_baud_rate = LibSerial::BaudRate::BAUD_115200;
      return true;
    case 230400:
      out_baud_rate = LibSerial::BaudRate::BAUD_230400;
      return true;
    default:
      return false;
  }
}

}  // namespace

void MotorDriver::Setup(const std::string& serial_device, int32_t baud_rate, int32_t timeout_ms) {
  timeout_ms_ = timeout_ms;
  try {
    serial_port_.Open(serial_device);
  } catch (std::exception& e) {
    std::cerr << "Failed to open serial port '" << serial_device << "': " << e.what() << std::endl;
    return;
  }

  if (!serial_port_.IsOpen()) {
    std::cerr << "Serial port '" << serial_device << "' is not open." << std::endl;
    return;
  }

  LibSerial::BaudRate serial_baud_rate = LibSerial::BaudRate::BAUD_57600;
  if (!TryToLibSerialBaudRate(baud_rate, serial_baud_rate)) {
    std::cerr << "Unsupported baudrate " << baud_rate
              << ", falling back to 57600." << std::endl;
  }

  // Configure the serial port.
  serial_port_.SetBaudRate(serial_baud_rate);
  serial_port_.SetCharacterSize(LibSerial::CharacterSize::CHAR_SIZE_8);
  serial_port_.SetParity(LibSerial::Parity::PARITY_NONE);
  serial_port_.SetStopBits(LibSerial::StopBits::STOP_BITS_1);
  serial_port_.SetFlowControl(LibSerial::FlowControl::FLOW_CONTROL_NONE);
  serial_port_.SetDTR(false);
  serial_port_.SetRTS(false);
  // Flush buffers.
  serial_port_.FlushIOBuffers();
}

bool MotorDriver::is_connected() const { return serial_port_.IsOpen(); }

void MotorDriver::SendEmptyMsg() { std::string response = SendMsg(""); }

MotorDriver::Encoders MotorDriver::ReadEncoderValues() {
  static const std::string delimiter = " ";

  const std::string response = SendMsg("e");
  const size_t del_pos = response.find(delimiter);
  const std::string token_1 = response.substr(0, del_pos).c_str();
  const std::string token_2 = response.substr(del_pos + delimiter.length()).c_str();
  return {std::atoi(token_1.c_str()), std::atoi(token_2.c_str())};
}

void MotorDriver::SetMotorValues(int val_1, int val_2) {
  auto clamp_pwm = [](int value) -> int {
    if (value > 255) return 255;
    if (value < -255) return -255;
    return value;
  };
  std::stringstream ss;
  // TEMPORARY MODE (manual drive without encoders):
  // send direct PWM command instead of closed-loop ticks command.
  ss << "o " << clamp_pwm(val_1) << " " << clamp_pwm(val_2);
  // Firmware may not reply reliably; avoid blocking control loop.
  SendMsgNoResponse(ss.str());
}

void MotorDriver::SetPidValues(float k_p, float k_d, float k_i, float k_o) {
  std::stringstream ss;
  ss << "u " << k_p << ":" << k_d << ":" << k_i << ":" << k_o;
  SendMsg(ss.str());
}

std::string MotorDriver::SendMsg(const std::string& msg) {
  if (!serial_port_.IsOpen()) {
    std::cerr << "Serial port is not open. Can't send message '" << msg << "'." << std::endl;
    return "";
  }
  // Add carriage return to the message.
  const std::string msg_to_send = msg + '\r';
  // Send the message.
  serial_port_.Write(msg_to_send);

  // Get response from the motor driver.
  std::string response;
  try {
    serial_port_.ReadLine(response, '\n', timeout_ms_);
  } catch (LibSerial::ReadTimeout&) {
    std::cerr << "Response to " << msg << " timed out." << std::endl;
  }
  return response;
}

void MotorDriver::SendMsgNoResponse(const std::string& msg) {
  if (!serial_port_.IsOpen()) {
    std::cerr << "Serial port is not open. Can't send message '" << msg << "'." << std::endl;
    return;
  }
  const std::string msg_to_send = msg + '\r';
  serial_port_.Write(msg_to_send);
}

}  // namespace andino_base
