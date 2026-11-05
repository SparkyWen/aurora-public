#include "../single_instance.h"

#include <windows.h>

#include <iostream>
#include <stdexcept>
#include <string>

namespace {
constexpr DWORD kEngineStarted = 42;

void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

std::wstring UniqueName(const wchar_t* purpose) {
  return L"Local\\Aurora.GuardTest." + std::to_wstring(GetCurrentProcessId()) +
         L"." + purpose;
}

class Child {
 public:
  explicit Child(const std::wstring& arguments) {
    wchar_t executable[MAX_PATH];
    Require(GetModuleFileNameW(nullptr, executable, MAX_PATH) != 0,
            "cannot locate test executable");
    std::wstring command = L"\"" + std::wstring(executable) + L"\" " + arguments;
    STARTUPINFOW startup{};
    startup.cb = static_cast<DWORD>(sizeof(startup));
    Require(CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE, 0,
                           nullptr, nullptr, &startup, &process_) != FALSE,
            "cannot start test child");
  }

  ~Child() {
    if (WaitForSingleObject(process_.hProcess, 0) == WAIT_TIMEOUT) {
      TerminateProcess(process_.hProcess, 99);
      WaitForSingleObject(process_.hProcess, 3000);
    }
    CloseHandle(process_.hThread);
    CloseHandle(process_.hProcess);
  }

  DWORD Wait() {
    // Pump the window messages that a secondary process's ShowWindowAsync
    // queues to this process while waiting for that child to finish.
    const ULONGLONG deadline = GetTickCount64() + 10000;
    while (WaitForSingleObject(process_.hProcess, 10) == WAIT_TIMEOUT) {
      MSG message;
      while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
      }
      Require(GetTickCount64() < deadline, "test child did not finish");
    }
    DWORD code = 0;
    Require(GetExitCodeProcess(process_.hProcess, &code) != FALSE,
            "cannot read test child exit");
    return code;
  }

 private:
  PROCESS_INFORMATION process_{};
};

DWORD Attempt(const std::wstring& name, bool legacy = false) {
  return Child((legacy ? L"--attempt-legacy \"" : L"--attempt \"") + name + L"\"").Wait();
}

void DuplicateCannotStartEngine(bool legacy) {
  const auto name = UniqueName(L"duplicate");
  SingleInstance primary(name.c_str());
  Require(primary.is_primary(), "first instance must acquire ownership");
  Require(Attempt(name, legacy) == 0,
          "second instance entered the engine/owner-claim path");
}

void ExitAllowsNextLaunch() {
  const auto name = UniqueName(L"relaunch");
  {
    SingleInstance primary(name.c_str());
    Require(primary.is_primary(), "first instance must acquire ownership");
    Require(Attempt(name) == 0, "duplicate was allowed while owner was alive");
  }
  Require(Attempt(name) == kEngineStarted,
          "next launch could not acquire ownership after the first exited");
}

void AbandonedOwnerAllowsNextLaunch() {
  const auto name = UniqueName(L"abandoned");
  const auto event_name = name + L".ready";
  HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, event_name.c_str());
  Require(ready != nullptr, "cannot create owner-ready event");
  HANDLE retained = CreateEventW(nullptr, TRUE, FALSE, (event_name + L".retained").c_str());
  Require(retained != nullptr, "cannot create retained-mutex event");
  {
    Child owner(L"--abandon \"" + name + L"\" \"" + event_name + L"\"");
    Require(WaitForSingleObject(ready, 5000) == WAIT_OBJECT_0,
            "owner did not acquire mutex");
    // Keep the mutex object alive after the child exits so the next launch
    // observes WAIT_ABANDONED rather than simply creating another object.
    HANDLE held = OpenMutexW(SYNCHRONIZE, FALSE, name.c_str());
    Require(held != nullptr, "cannot retain abandoned mutex");
    SetEvent(retained);
    Require(owner.Wait() == 0, "abandoned-owner child did not exit");
    Require(Attempt(name) == kEngineStarted,
            "next launch rejected an abandoned owner");
    CloseHandle(held);
  }
  CloseHandle(ready);
  CloseHandle(retained);
}

void ExistingWindowIsRestored() {
  const auto name = UniqueName(L"window");
  SingleInstance primary(name.c_str());
  Require(primary.is_primary(), "window owner must be primary");
  HWND window = CreateWindowExW(0, L"STATIC", L"Aurora test window",
                               WS_OVERLAPPEDWINDOW, 0, 0, 320, 200,
                               nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  Require(window != nullptr, "cannot create test window");
  Require(primary.RegisterWindow(window), "cannot register primary window");
  for (int command : {SW_HIDE, SW_MINIMIZE}) {
    ShowWindow(window, command);
    Require(Attempt(name) == 0, "window wakeup started another engine");
    const ULONGLONG deadline = GetTickCount64() + 2000;
    while ((!IsWindowVisible(window) || IsIconic(window)) &&
           GetTickCount64() < deadline) {
      MSG message;
      while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
      }
      Sleep(10);
    }
    Require(IsWindowVisible(window) && !IsIconic(window),
            "existing hidden/minimized window was not restored");
  }
  DestroyWindow(window);
}
}  // namespace

int wmain(int argc, wchar_t* argv[]) {
  try {
    if (argc >= 3 && std::wstring(argv[1]) == L"--attempt-legacy") {
      // Old runner behavior model only: no mutex check before Flutter/Dart.
      // This is never linked or enabled in the production application.
      return kEngineStarted;
    }
    if (argc >= 3 && std::wstring(argv[1]) == L"--attempt") {
      SingleInstance instance(argv[2]);
      Require(instance.valid(), "instance guard failed");
      if (instance.is_primary()) return kEngineStarted;
      instance.ActivateExistingWindow(100);
      return 0;
    }
    if (argc == 4 && std::wstring(argv[1]) == L"--abandon") {
      SingleInstance instance(argv[2]);
      Require(instance.is_primary(), "abandoned owner could not start");
      HANDLE ready = OpenEventW(EVENT_MODIFY_STATE, FALSE, argv[3]);
      Require(ready != nullptr, "cannot signal ownership");
      HANDLE retained = OpenEventW(SYNCHRONIZE, FALSE, (std::wstring(argv[3]) + L".retained").c_str());
      Require(retained != nullptr, "cannot wait for retained mutex");
      SetEvent(ready);
      // Exit without destructors after the parent retained the object,
      // reproducing the OS cleanup of a crashed GUI process.
      Require(WaitForSingleObject(retained, 5000) == WAIT_OBJECT_0,
              "parent did not retain mutex");
      ExitProcess(0);
    }
    const bool legacy = argc == 2 && std::wstring(argv[1]) == L"--legacy-model";
    DuplicateCannotStartEngine(legacy);
    ExitAllowsNextLaunch();
    AbandonedOwnerAllowsNextLaunch();
    ExistingWindowIsRestored();
    std::cout << "PASS: duplicate launch, relaunch, abandoned owner, window restore\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    return 1;
  }
}
