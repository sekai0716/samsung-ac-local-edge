# Samsung AC Local Edge — 설계·검증 프로젝트

삼성 스탠드형 무풍 에어컨을 SmartThings 허브의 LAN Edge 드라이버로 제어하기 위한 Lua 구현과 검증 도구입니다.

이 저장소에는 소스·표시 설정·테스트·식별자를 제거한 관측 기록을 보관합니다. 운영 개인 키, 클라이언트 인증서, `dist/` 배포 패키지, `private-diagnostics/` 원문 로그는 포함하지 않습니다. `assets/ocf-root-ca.pem`은 서버 인증서 검증용 공개 CA입니다.

현재 설치본은 **IP 입력 없는 자동 검색과 전원·설정 온도·운전 모드·풍량·무풍·자동건조·청정·상하 바람문·청소용 패널 열림·허브 켜짐/꺼짐 예약**을 화면에 제공합니다. 승인된 동일 운영 인증 자료를 재사용해 v3 허브에 설치했고, **상시 PC/NAS 없이 허브에서 인증 GET과 설정 POST를 수행**합니다. 냉방·제습과 선택형 청정을 분리하고 PM10·PM2.5·PM1.0·GAS 단계·실내 청정도를 표시합니다. 기본 조회 간격은 10초입니다.

**센서 카드 수정본 `2026-10-20T15:53:11.604884434`을 허브에 설치했습니다.** 상세 화면의 기존 온습도·공기질 그래프를 빼고, ‘실내 환경’ 카드에 온도·습도·청정도·PM10·PM2.5·PM1.0·GAS를 표시합니다. 본체의 `AirMonitoring_On`을 읽었을 때만 값을 표시하며, Off나 상태 미확인 때는 `-`로 지우고 비활성화합니다. 표준 센서 capability와 기존 루틴은 유지하되 Off 동안에는 새 숫자 측정 이벤트를 발행하지 않습니다. 기존 기록을 삭제하지 않습니다. 실제 Off→On→Off 표시값과 전원·예약 보존을 확인했습니다. 새 카드의 서버 상태 검증과 휴대폰 렌더링 확인은 구분합니다. [센서 카드 검증 기록](docs/observed-sensor-card.json)

같은 값 선택의 상태 응답 수정도 유지합니다. 본체 GET으로 확인한 해당 속성은 다시 발행하고 본체 중복 POST는 생략합니다. 기기 예약은 상세 화면에서 숨기고 허브 예약만 ‘예약’으로 제공합니다. 이전 설치본에서 실제 허브 명령 8회의 같은 값 서버 상태 갱신, 본체 POST 0회, 전원 Off·본체 및 허브 예약 없음·ONLINE을 확인했습니다. 휴대폰에서 로딩이 해제되는 렌더링은 별도 확인 대상입니다. [재선택·화면 검증 기록](docs/observed-selection-ack.json)

화면은 **실내 환경, 운전, 희망 온도, 바람 설정, 무풍·청정, 예약, 기기 설정, 본체 화면, 자동청소, 청소용 패널**로 구성했습니다. 목록·슬라이더·토글이 별도 카드로 나뉘어도 같은 제목이 반복되지 않도록 카드별 제목을 구분했습니다. 한국어 번역은 `capabilities/translations/`, 전체 화면 구성은 `capabilities/ac-device-config.json`에 있습니다. 기존 계정의 custom capability ID와 화면 ID가 들어 있으므로 다른 계정에서 사용할 때에는 해당 계정에 정의와 번역을 등록하고 화면을 생성해야 합니다. 등록·갱신 절차와 검증 범위는 [표시·설정 구현 안내](docs/control.md)에 있습니다.

기존 Gear→AI 추정은 실제 `4.00` 거부로 폐기했습니다. AI는 `ComfortAICooling_On/Off`이며 PC에서 설정·해제 후 GET을 확인했습니다. 스마트쾌적은 별도 `Auto` 모드입니다. 명시적 명령 거부는 오프라인으로 처리하지 않습니다. 같은 상태의 주기 조회는 반복 발행을 줄이고 초기·변경 이벤트를 초당 최대 4개로 전달합니다. 효과음이 음소거로 남던 문제는 설정 이벤트의 명시적 변경 처리 후 서버 상태 갱신을 확인했습니다. 센서 카드 수정본의 Lua 5.3 검사 99개, capability 스키마 이벤트 641개와 Python 검사 22개가 통과했습니다. 모의 통신 검사는 본체의 실제 예약 만료 시험과 구분합니다. 기능별 과거 실기 범위는 [제어 기록](docs/observed-controls-v2.json), 현재 예약의 실기 범위와 한계는 [후속 시험 기록](docs/observed-native-timer-trial.json)을 따릅니다.

‘예약’은 허브에 시각을 저장하고 만료 때 전원 명령을 한 번 요청합니다. 이 메뉴에서 30분을 선택해도 본체에 예약이 저장되지 않습니다. 기존 허브 예약의 저장·취소·재시작 복구는 유지하며 본체 예약으로 자동 이전하지 않습니다. 숨긴 ‘기기 예약’의 capability와 기존 루틴 호환성은 유지합니다. 본체에서 읽은 0은 예약 없음 상태지만, 0 전송 시험에서 전원 켜짐·꺼짐을 재현했으므로 운영 드라이버는 0 입력을 계속 차단합니다. 양수 본체 예약 수락과 0 전송·리모컨 취소의 실기 범위는 [예약 시험 기록](docs/observed-native-timer-trial.json)에 보존합니다. 안전한 로컬 취소 명령, 실제 30분 만료와 전체 1~48 범위의 실기 수락은 미검증입니다.

- [설계와 구현 가능성 판단](docs/design.md)
- [에어컨 표시·설정 구현과 검증 범위](docs/control.md)
- [읽기 전용 Lua 프로토타입·검증·재현](docs/prototype.md)
- [동일 Lua 코드의 PC 실기 결과](docs/observed-lua-pc.json)
- [IP 입력 없이 찾은 실제 에어컨](docs/observed-discovery.json)
- [허브 단독 조회·연결 재사용·온라인 상태 확인](docs/observed-hub.json)
- [AI 모드·청정·자동건조와 화면 정의 확인](docs/observed-features.json)
- [AI 수정·센서·바람문·예약의 최신 실기 검증](docs/observed-controls-v2.json)
- [본체 예약 설정·0 전송·리모컨 취소 비교](docs/observed-native-timer-trial.json)
- [실내 환경 카드·측정 On/Off 표시 검증](docs/observed-sensor-card.json)
- [개인 식별자를 제외한 실제 응답](docs/observed-device.json)
- [전체 조회 항목과 추가 기능 설계](docs/capability-inventory.md)
- [65개 개별 GET의 실제 결과](docs/observed-resources.json)
- [참고 소스 버전과 공개 CA 출처](docs/references.json)
- [읽기 전용 검증 도구](tools/readonly_probe.py)

## 확인한 내용

2026-10-19에 `A20_FAC_BORA_18K / TizenRT2.0` 장비에서 동적 TCP 포트 탐색, TLS 1.2, 공개 OCF CA에 의한 서버 인증서 체인 검증, 임시 클라이언트 인증서를 사용한 상태 GET을 확인했습니다. 공개·암호화 경로에서 읽은 OCF 장비 식별자도 일치했습니다.

초기 읽기 시험에서는 전원, 현재·설정 온도, 동작 모드, 풍량, 습도를 읽었습니다. 당시 전원 Off 상태에서 `fivepercentHumidity`는 63, 일반 습도 필드는 0이었습니다. 이후 습도 42·47·48·53% 변화와 SmartThings 이력 저장을 확인했습니다. 센서 정확도는 별도 검증하지 않았습니다. 초기 읽기 시험의 임시 키는 삭제했고, 이후 설정 시험에는 승인된 운영 인증 자료를 재사용했습니다. 등록·소유권 설정은 변경하지 않았습니다. 초기 시험에는 없었던 `AirMonitoring_On` 전송은 이후 사용자가 요청한 별도 시험에서 확인했으며, 운영 드라이버의 주기 조회는 이 명령을 자동으로 보내지 않습니다.

전체 디렉터리와 배치를 대조해 상태·진단 경로 65개를 개별 GET했습니다. 59개가 성공했고 이 중 19개는 실제 빈 응답이었습니다. 서버 오류·GET 불허·경로 없음 응답은 각각 2개였습니다. 먼지 3종·공기 등급·냄새·순간 전력·누적 카운터·소모품·알람·추가 옵션을 확인해 설계에 포함했습니다. 센서 정확도·최신성과 누적 전력량의 kWh 환산은 아직 확정하지 않았습니다.

## 개발 PC에서 재현

검증 환경은 Python 3.12입니다. 아래 인증 시험은 본인이 소유하고 해당 인증 방식을 승인한 기기에 실행합니다. `--host`에는 실제 장비 주소를 넣습니다.

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements-probe.txt
.venv/bin/python -m unittest discover -s tests -v

# 공개 정보와 광고된 TLS 포트만 조회
.venv/bin/python tools/readonly_probe.py --host 192.168.1.170

# 임시 인증서로 상태를 읽고, 공개 CA로 서버 인증서 체인도 검증
.venv/bin/python tools/readonly_probe.py --host 192.168.1.170 \
  --authenticated-read --server-ca assets/ocf-root-ca.pem \
  --output private-diagnostics/latest.json

# 전체 디렉터리와 배치에 광고된 상태 경로를 각각 GET
.venv/bin/python tools/readonly_probe.py --host 192.168.1.170 \
  --authenticated-read --server-ca assets/ocf-root-ca.pem --all-state-reads \
  --output private-diagnostics/all-resources.json
```

`assets/ocf-root-ca.pem`은 공개 서버 CA 인증서입니다. 개인 키가 아닙니다. 장비 UUID·원문 응답·Wi-Fi 정보는 출력하지 않으며, 상태 응답은 허용한 필드만 기록합니다. CA 검증과 DNS 호스트명 검증은 구분하며, OCF 식별자를 DNS 이름으로 검증하지는 않습니다.

`--server-ca`가 없는 인증 실행은 서버 체인을 검증하지 않는 진단 모드입니다. 설계의 기본 검증 명령은 위와 같이 공개 CA를 지정합니다. 도구에는 POST·PUT·DELETE 또는 소유권·등록 설정을 변경하는 기능이 없습니다.

IP 입력 없이 실제 Lua 검색 코드를 시험하려면 다음을 실행합니다. 이 검색은 인증서 없이 공개 GET만 사용합니다.

```bash
.venv/bin/pip install -r requirements-lua-pc.txt
.venv/bin/python tools/lua_discovery_probe.py --output private-diagnostics/discovery.json
```

드라이버 시작과 앱 검색에서 같은 LAN의 OCF 멀티캐스트 응답을 받고, 삼성 제조사·지원 모델·장비 ID·광고된 TLS 포트를 확인합니다. 현재 자동 추가 대상은 확인한 보드 `A20_FAC_BORA_18K`입니다. 검색한 주소는 기기에 저장하고, 주소 변경 시에는 동일 ID를 다시 찾도록 구현했습니다. 허브의 실제 검색·생성은 성공했으며 실제 DHCP 주소 변경은 미검증입니다.

## 검증 범위

Python 검사 22개가 통과했습니다. 기존 읽기 검사 15개는 TCP 분할 수신, RFC 8323 길이, 토큰, 접근 거부, 동적 포트, false/0, 개인 정보 제외, 부분 실패와 인덱스를 확인합니다. 추가 2개는 IP 없는 패키지 생성과 선택적인 검색 후보 주소 검증을 확인하고, 화면 검사 5개는 카드 제목·스위치·활성 조건·예약 목록·센서 카드의 계약을 확인합니다.

Lua 5.3 검사 99개가 통과했습니다. 이전 버전에서 PC 검색·GET도 확인했습니다. main에는 표준 capability 11개와 custom capability 13개가 있습니다. 상세 화면은 위 10개 그룹으로 구분하며, 운전의 모드·풍량 목록과 희망 온도 슬라이더를 별도 카드로 표시합니다. 무풍·청정·본체 화면·자동청소에는 길쭉한 On/Off 스위치를 사용합니다. 기존 표준 모드·온도·풍량 capability와 부가 switch 8개·패널 `doorControl` component는 루틴 호환을 위해 유지합니다. 무풍은 전원이 켜진 냉방·제습·청정에서만 허용하고 청소용 패널은 전원이 꺼져 있을 때만 제어합니다. 이전 허브 시험에서 실제 패널 열기·닫기와 전원 Off 유지를 확인했습니다. 본체 설정은 필요한 필드만 POST하고 확인 GET의 관측값을 표시합니다. 허브 예약의 설정·취소는 본체에 쓰지 않습니다. 자동건조 사용 설정은 `Autoclean_On/Off`로만 판정하며 진행률·Idle 상태나 기본값으로 대체하지 않습니다. 세부 허용 값·제약·재현 명령은 [설정 구현 안내](docs/control.md)에 있습니다.

CLI 로그인 후 `V3_HUB`, 펌웨어 `000.062.00007`을 확인했습니다. 소유 전용 채널 `Samsung AC Local Private`으로 수정본을 배포합니다. 36,500일 인증서의 만료일은 2126-09-25이며, 키 포함 패키지를 `api.smartthings.com`에 전송한다는 명시 승인을 받았습니다. 비지원 `ip-multicast-ttl` 옵션을 제거한 뒤 자동 추가가 성공했습니다. TLS 진단 전용 코드는 운영본에 포함하지 않았고 공개 초대는 만들지 않았습니다.

공식 SSL·LAN 문서와 API v21 SDK를 대조했습니다. 에어컨이 TCP 연결 직후 먼저 TLS `ClientHello`를 보내는 경우를 실제 수신했습니다. `tls_bridge.lua`는 허브의 ClientHello를 준비한 뒤 기기에 연결하고 암호문만 내부 전달합니다. 관측한 역할 충돌만 요청 전에 최대 6회 재접속하며, 성공한 인증 연결은 재사용합니다. 재사용 중에는 UDP 탐색을 반복하지 않고 TLS 내부 기기 ID를 매번 확인합니다. 새 연결은 공개 탐색과 서버 CA 검증을 거칩니다. POST 이후 자동 재전송은 하지 않습니다.

과거 연결 재사용 버전은 새로고침 5회 성공과 4분 유휴 후 복구를 확인했으나 이후 간헐 실패도 관측했습니다. 최신 수정은 명령 거부와 연결 실패를 구분하며, 짧은 성공 관측을 장기 안정성으로 확대하지 않습니다. 실제 설정 시험과 취소·복원 결과는 최신 관측 기록에 따로 남깁니다. 과거 사용자 화면에서 온습도와 공기질 표시를 확인했으며, 현재는 사용자 요청으로 상세 화면의 그래프를 별도 센서 카드로 교체했습니다. 인터넷 단절 상황은 시험하지 않았습니다. 8888/HTTPS와 구형 2878 경로는 이 장비에서 연결을 거부했습니다.
