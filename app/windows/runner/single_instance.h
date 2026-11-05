#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

#include <string>

// One GUI per interactive Windows session. Keeping the mutex owned until
// process exit prevents two Dart supervisors from claiming the same tunnel.
class SingleInstance {
 public:
  explicit SingleInstance(const wchar_t* name = L"Local\\Aurora.GUI.SingleInstance");
  ~SingleInstance();

  SingleInstance(const SingleInstance&) = delete;
  SingleInstance& operator=(const SingleInstance&) = delete;

  bool valid() const { return valid_; }
  bool is_primary() const { return primary_; }
  bool RegisterWindow(HWND window) const;
  bool ActivateExistingWindow(DWORD timeout_ms = 5000) const;

 private:
  const std::wstring name_;
  HANDLE mutex_ = nullptr;
  bool valid_ = false;
  bool primary_ = false;
};

#endif  // RUNNER_SINGLE_INSTANCE_H_
