#ifndef LocalCurtain_h
#define LocalCurtain_h

// 원격 세션 중 로컬 사용자가 화면을 보거나 조작하지 못하도록 가림 (Windows 의 콘솔 잠금과 유사)
//  - 물리 디스플레이는 gamma 를 0 으로 설정하여 검게 표시 (패널 전원은 건드리지 않음)
//    gamma 는 설정한 앱이 종료되면 macOS 가 자동으로 복원하므로 agent 가 비정상 종료되어도 화면이 복구됨
//  - 로컬 키보드/마우스 입력은 HID event tap 으로 차단 (agent 가 주입한 원격 입력만 통과)
// 클라이언트 전환 시 두 VirtualMonitor 가 공존하므로 프로세스 단위로 참조 카운트를 관리
class LocalCurtain {
public:
    static void Acquire();
    static void Release();

    // 디스플레이 구성이 바뀐 경우 (새 모니터 연결, 미러링 변경 등) 다시 적용
    static void Refresh();
};

#endif /* LocalCurtain_h */
