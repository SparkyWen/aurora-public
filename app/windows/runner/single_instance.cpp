#include "single_instance.h"

namespace {
struct WindowSearch {
  const wchar_t* property;
  HWND window = nullptr;
};

BOOL CALLBACK FindPrimaryWindow(HWND window, LPARAM parameter) {
  auto* search = reinterpret_cast<WindowSearch*>(parameter);
  if (GetPropW(window, search->property) != nullptr) {
    search->window = window;
    return FALSE;
  }
  return TRUE;
}
}  // namespace

SingleInstance::SingleInstance(const wchar_t* name) : name_(name) {
  mutex_ = CreateMutexW(nullptr, FALSE, name_.c_str());
  if (mutex_ == nullptr) return;
  const DWORD result = WaitForSingleObject(mutex_, 0);
  primary_ = result == WAIT_OBJECT_0 || result == WAIT_ABANDONED;
  valid_ = primary_ || result == WAIT_TIMEOUT;
}

SingleInstance::~SingleInstance() {
  if (primary_) ReleaseMutex(mutex_);
  if (mutex_ != nullptr) CloseHandle(mutex_);
}

bool SingleInstance::RegisterWindow(HWND window) const {
  return primary_ &&
         SetPropW(window, name_.c_str(), reinterpret_cast<HANDLE>(ULONG_PTR{1}));
}

bool SingleInstance::ActivateExistingWindow(DWORD timeout_ms) const {
  const ULONGLONG deadline = GetTickCount64() + timeout_ms;
  do {
    WindowSearch search{name_.c_str()};
    EnumWindows(FindPrimaryWindow, reinterpret_cast<LPARAM>(&search));
    if (search.window != nullptr) {
      // Async restoration does not wait on a busy Flutter UI thread. Windows
      // may decline foreground focus, but the existing window is still shown.
      ShowWindowAsync(search.window, SW_RESTORE);
      SetForegroundWindow(search.window);
      return true;
    }
    if (GetTickCount64() >= deadline) return false;
    Sleep(50);
  } while (true);
}
