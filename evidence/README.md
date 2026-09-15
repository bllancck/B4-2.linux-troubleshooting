# 증거 파일 읽는 법

최종 리포트는 `final/` 아래의 새 실험 결과를 사용합니다. 장애마다 다음 순서로 필요한 파일만 확인합니다.

1. `settings.txt`: Before와 After에서 바꾼 환경변수
2. `application.log`: 애플리케이션이 기록한 장애 현상과 종료 이유
3. `monitor.log`: `monitor.sh`가 기록한 CPU·메모리 변화와 PID 생존 여부
4. `process-final.txt`, `threads-final.txt`: Deadlock에서만 확인하는 프로세스·스레드 상태
5. `result.txt`: 종료 코드와 관찰자 종료 여부

```text
final/
├── oom-before/
├── oom-after/
├── cpu-before/
├── cpu-after/
├── deadlock-before/
└── deadlock-after/
```

기존의 타임스탬프 폴더들은 재편 전 자동 수집 결과입니다. 과거 기록을 보존한 것이며 최종 판단에는 `final/` 결과만 사용합니다.

앱 로그와 Linux 관찰값은 역할이 다릅니다.

- 앱 로그는 “앱이 무엇을 감지하고 왜 종료했는지” 설명합니다.
- `monitor.log`, `ps`, `top`은 “Linux에서 프로세스가 어떻게 보였는지” 확인합니다.

특히 CPU 실험에서는 앱 내부 `Current Load`가 상승했지만 Linux `%CPU`는 상승하지 않았습니다. 두 값을 같은 수치로 해석하면 안 됩니다.
