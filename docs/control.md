# 에어컨 표시와 로컬 설정 구현

갱신일: 2026-10-20, Asia/Seoul.

읽기 단계에서 설정 가능한 Edge 드라이버로 확장했습니다. main은 `AirConditioner` 분류와 `oic.d.airconditioner` 메타데이터를 사용합니다. 운영 패키지 업로드·v3 허브 설치·자동 추가·허브 단독 GET과 실제 POST를 확인했습니다. 최신 버전·기능별 설정·취소·복원 범위는 [현재 실기 기록](observed-controls-v2.json)을 따릅니다. [이전 기능 기록](observed-features.json)은 당시 관측을 보존한 자료이며 Gear→AI와 자동 모드의 청정 해석은 이후 폐기했습니다.

## 구현한 기능

상세 화면의 조작부는 운전, 바람·청정, 예약, 기기 설정, 관리 메뉴로 묶습니다. 운전은 `samsungAcLocalOperation`의 모드 선택·희망 온도 슬라이더·바람 세기 선택 세 항목을 한 카드에 배치합니다. 바람·청정은 `samsungAcLocalComfort`, 기기 설정은 `samsungAcLocalDeviceSettings`, 관리는 `samsungAcLocalCare`로 묶습니다. 아래의 기존 capability와 component는 루틴 호환을 위해 유지하며 상세 화면에서 중복 표시하지 않습니다. 운전 카드의 명령은 기존 모드·온도·풍량 작업 큐로 전달하고 같은 본체 관측값을 발행합니다. 생성 원본은 `tools/build_menu_capabilities.py`이고 JSON 정의·표시·테스트 스키마를 함께 생성합니다.

그룹 제목은 `capabilities/translations/`의 `*-ko.json`과 기본 언어용 `*-en.json`에 같은 한글 `label`로 관리합니다. 이 드라이버는 메뉴 문구를 한글로 제공하므로 앱이 언어를 지정하지 않아도 같은 제목을 사용합니다. `Samsung AC Local` 접두사를 빼고 ‘운전’, ‘바람·청정’, ‘예약’, ‘기기 설정’, ‘관리’로 표시하며, 루틴 호환용 기존 설정 그룹은 ‘라이팅·음성’으로 구분합니다. 등록용 capability `name`과 ID는 유지합니다. 번역 파일은 생성기와 별도로 관리하며, 대응하는 `*-presentation.json`의 ID에 `smartthings capabilities:translations:upsert <ID> --capability-version 1 --input <번역 파일>`로 등록합니다. 기존 해당 언어 번역에 다른 필드가 있으면 보존하고 `label`만 병합합니다. 방식은 [SmartThings Capability Translations 문서](https://developer.smartthings.com/docs/devices/capabilities/capability-translations)를 따릅니다.

기기 화면 구성 원본은 `capabilities/ac-device-config.json`입니다. 그룹 번역을 등록한 뒤 `smartthings presentation:device-config:create --input capabilities/ac-device-config.json --json`으로 화면을 생성하고, 반환된 `vid`와 `mnmn`을 `driver/profiles/samsung-ac.yml`의 `metadata.vid`와 `metadata.mnmn`에 함께 연결해 패키징합니다. 방식은 [공식 Edge 화면 지정 절차](https://developer.smartthings.com/docs/devices/configurations-and-presentations/device-presentations#using-device-presentations-with-smartthings-edge-drivers)를 따릅니다. 상세 화면·루틴·대시보드의 순서, 범위, 활성 조건은 이 JSON에 보존합니다.

기존 구성과 동일한 입력으로 화면을 다시 생성했을 때 이전 영어 제목이 남은 화면 ID가 재사용됐습니다. 운전 카드의 기존 ‘운전 모드’ 문구를 구성에 명시해 새 화면을 생성하고, 한국어·영어·언어 미지정 조회에서 모두 한글 그룹 제목인지 확인합니다. 명시한 문구는 기존과 같으며 조작부·활성 조건·루틴의 생성 결과도 이전 화면과 대조합니다.

번역 등록 결과와 설치된 기기의 화면 정보는 따로 확인합니다. 이번 확인에서 동일 소스 재업로드와 프로필 메타데이터 변경만으로는 기존 Device Presentation의 영어 제목이 유지됐습니다. 자동 생성용 `deviceConfig`와 capability별 `config`를 함께 넣었을 때에는 명시한 `vid`도 적용되지 않아, 표시 설정을 위 JSON으로 분리했습니다. 구성이나 번역을 변경하면 화면을 다시 생성하고, 설치된 기기의 `presentationId`와 `manufacturerName`이 생성 결과의 두 값과 일치하는지 확인합니다. 기기 정보에 값이 없으면 임의 기본값으로 대체하지 않으며, 기기에 저장된 쌍으로 직접 화면을 조회해 한국어 그룹 제목과 기존 조작부를 대조합니다. 이름 변경에 에어컨 제어 명령은 필요하지 않습니다.

한글 화면 지정 후 앱의 연결 오류를 조사했을 때, 허브는 인증 GET을 계속 성공했지만 기기의 `manufacturerName`이 비어 있었습니다. 해당 제조사 값으로 화면을 조회하면 HTTP 422가 반환됐고 생성 당시 제조사 `SmartThingsCommunity`로 조회하면 정상 응답했습니다. 이전 검증은 생성 결과의 제조사를 대신 사용해 이 누락을 놓쳤습니다. 프로필에 `mnmn`을 명시하고 실제 기기 정보의 두 값을 검증하도록 수정했습니다. 휴대폰 화면의 복구 여부는 이 API 검증과 별도로 확인합니다.

바람문은 닫힘·상단만·하단만·상하단 중 하나를 선택해 `Blooming`을 한 번만 전송합니다. 운전 옵션은 일반·스피드·정음이며 무풍과 청정은 별도 On/Off 토글입니다. ‘일반’은 스피드·정음만 해제하고 이미 켠 무풍은 유지합니다. 본체 화면의 켜짐은 기존 화면 끄기 옵션의 해제(`Display_Off`)를 뜻합니다. 청소용 패널은 운전용 바람문과 구분합니다. 예약 취소는 각 예약 메뉴의 ‘예약 없음 (취소)’로 합치며 기존 취소 명령은 루틴에서 유지합니다.

| 앱 기능 | capability / component | 로컬 POST 경로와 필드 |
|---|---|---|
| 전원 On/Off | `switch` / main | `/power/vs/0`: `x.com.samsung.da.power` = `On` / `Off` |
| 설정 온도 | `thermostatCoolingSetpoint` / main | `/temperature/desired/0`: `temperature` 숫자 |
| 운전 모드 | `airConditionerMode` / main | `/mode/vs/0`: `x.com.samsung.da.modes` 배열 |
| 풍량 | `airConditionerFanMode` / main | `/airflow/vs/0`: `x.com.samsung.da.speedLevel` 문자열 |
| 무풍 On/Off | `switch` / windfree | `/mode/vs/0`: `x.com.samsung.da.options`의 `Comode_*` 토큰 |
| 청정 On/Off | `switch` / purify | `/mode/vs/0`: 냉방 `Cool`↔`CoolClean`, 제습 `Dry`↔`DryClean` |
| 자동 건조 On/Off | `switch` / autoclean | 같은 옵션의 `Autoclean_On` / `Autoclean_Off` |
| 현재 온도·습도 | `temperatureMeasurement`, `relativeHumidityMeasurement` | 기존 배치 GET에서 조회 |
| 상·하 바람문 | `switch` / doorupper, doorlower | `Blooming_0..3` 중 필요한 비트만 변경 |
| 바람문(패널) 열림 | `doorControl` / panel | 청소용 `Panel_Open/Close` 단일 옵션. 전원 Off일 때만 허용 |
| 켜짐·꺼짐 예약 | `instantcommon43059.samsungAcLocalTimer` / main | 허브에 시각 저장. 만료 때 전원 명령 한 번. 설정·취소는 본체에 쓰지 않음 |
| 실내 먼지·GAS·청정도 | `dustSensor`, `veryFineDustSensor`, `odorSensor`, `airQualityHealthConcern` | 센서 배치 GET. PM 단위·GAS 1단계·좋음 대조 |
| 스피드·정음 | `switch` / speed, quiet | `Comode_Speed/Quiet/Off` 단일 옵션. 냉방에서 허용, 운전 실기 미검증 |
| 라이팅·음성선택 | `instantcommon43059.samsungAcLocalSettings` / main | `Light_Off/Small/On/Huge`, `Volume_33/66/100/Melody/Mute` |
| 화면 끄기 | `switch` / displayoff | 켜짐=`Display_On`, 해제=`Display_Off` |

현재 장비가 광고한 온도 범위는 18~30℃입니다. 1℃ 간격은 장비 응답에 increment가 없어 참고 구현의 기본값을 적용한 것이며, 실기 쓰기로 확인한 간격은 아닙니다. 명령 직전에 새로 읽은 범위·단위·간격으로 검사하며 잘못된 값은 전송하지 않습니다.

모드 선택은 `aIComfort`(AI 인공지능 쾌적), `auto`(스마트 쾌적/자동), `cool`(냉방), `dry`(제습), `wind`(청정 단독/송풍) 다섯 항목입니다. `coolClean`, `dryClean`은 관측 상태와 기존 API 호환을 유지하고 상세 화면의 선택 목록에서는 빼 별도 청정 스위치로 조작합니다. 장비가 광고한 지원 목록에 있는 모드만 전송하며 `HOMECARE_WIZARD_V2`와 난방은 선택 대상으로 두지 않습니다. 모드를 바꿀 때 전원을 함께 켜지 않습니다.

Gear→AI 추정은 실제 Gear POST의 `4.00` 거부로 폐기했습니다. 기존 삼성 앱에서 AI를 선택했을 때 `ComfortAICooling_On`, `ArtificialWorking_Ing/On`을 읽었고 기본 모드는 Auto와 Cool 사이에서 변했습니다. PC에서 `ComfortAICooling_Off`와 `On`을 각각 단일 POST한 뒤 GET으로 반영을 확인했습니다. AI는 기본 모드와 별도의 선택 상태이며, AI 중에는 기본 모드가 변해도 UI에 인공지능 쾌적을 유지합니다. 일반 모드로 나갈 때는 요청한 모드와 `ComfortAICooling_Off`를 보냅니다. AI 학습·날씨 서버 기능 자체를 재구현한 것은 아닙니다.

청정 스위치는 냉방·제습에 추가하는 선택입니다. UI 기본 모드는 냉방/제습으로 표시하고 `CoolClean/DryClean`만 별도 청정 On으로 발행합니다. 청정을 켠 냉방↔제습 전환은 선택을 유지합니다. Smart Auto·AI·청정 단독을 선택형 청정 On으로 추정하지 않습니다. Auto/Wind에서 청정 On은 거부하고 이미 Off면 변경하지 않습니다. AI 중 수동 온도·풍량·무풍·청정 명령은 거부합니다. 메뉴에는 온도·풍량·무풍·청정·운전 옵션·청소용 패널의 활성 조건을 `visibleCondition`으로 지정합니다. 스마트폰에서의 렌더링 확인은 서버 정의 검증과 구분합니다.

자동건조는 기본 On/Off를 가정하지 않습니다. `Autoclean_On/Off`가 사용 설정이고 `AutocleanProgress_*`와 `StopAutoClean_*`는 별개입니다. 이번 실제 GET은 `Autoclean_Off`, 진행률 `1`, 종료 채널 `Idle`이었으며 진행률·Idle로 설정을 덮어쓰지 않습니다. 설정 토큰이 없으면 미확인으로 남기고 Off 이벤트를 만들지 않습니다. 출고 기본값이 On인지와 리모컨 표시와의 일치는 미검증입니다.

풍량은 참고 구현의 legacy 대응인 `auto/low/medium/high/turbo` ↔ `0/1/2/3/4`를 사용합니다. 현재 실기에서 읽은 코드는 `0`이며 나머지 단계와 각 운전 모드에서의 허용 여부는 실기 시험이 남았습니다. 풍향은 현재 값 `Off`와 참고 구현의 `Fix` 간 대응을 확인하지 못해 제어 기능에 포함하지 않았습니다.

무풍은 전원이 켜진 냉방·제습·청정에서만 On/Off 설정을 허용합니다. 명령 직전 GET에서 전원·AI 해제·운전 모드·무풍과 수면 상태를 확인하며, 누락 상태에서는 차단합니다. 전원이나 모드는 자동 변경하지 않습니다. `Comode_Nano`, 수면과 함께 쓰는 `Comode_NanoSleep`을 사용하며, 활성 수면의 `Sleep_*` 시간을 보존합니다. 끌 때도 수면이나 다른 프리셋은 유지합니다. 허브에서 사용자가 무풍을 조작한 뒤 `AC_COMMAND_CONFIRMED`를 관측했으나 세 모드 전체와 수면 병합의 실제 동작 확인은 별도로 구분합니다.

PM10·PM2.5·PM1.0의 값 5와 단위 μg/m³는 기존 삼성 capability 및 사용자 화면과 대조했습니다. GAS 원시 0은 화면 1단계로 확인했고 원시 0~3에는 +1을 적용하지만 다른 단계는 실측 대조하지 않았습니다. `CleanLevel=1`만 좋음으로 확인해 표시하며 다른 코드는 unknown입니다. 실외 CAI와 날씨는 로컬 센서로 제공하지 않습니다. 순간 전력·누적 카운터·필터 원시는 로그에 남기고 미확정 단위·환산을 계량 이벤트로 만들지 않습니다.

상단만 열림은 `Blooming_1`, 양쪽은 `Blooming_3`을 사용자 조작과 GET으로 대조했습니다. 각 스위치는 다른 문의 비트와 전원·모드를 보존합니다. 하단 단독 2의 실제 외관 대응과 장시간 동작은 별도 확인 대상입니다.

‘바람문(패널) 열림’은 청소용 기능으로 상·하 선택과 별도입니다. `Panel_Open`은 열림, `Panel_Close`는 닫힘으로 발행하며 상태가 없거나 알 수 없는 값이면 닫힘으로 추정하지 않습니다. 명령 직전 GET에서 전원 Off와 알려진 패널 상태를 확인한 경우에만 옵션 하나를 POST합니다. 전원을 자동으로 끄거나 켜지 않습니다. 허브에서 열기·닫기를 각각 한 번 실행해 본체 GET과 상태 API의 일치를 확인했으며 시험 후 닫힘·전원 Off·효과음 유지 상태를 확인했습니다. 본체에서 `Blooming`은 패널을 열 때 3, 닫을 때 0으로 함께 변했습니다. 드라이버가 별도의 Blooming 명령을 보낸 것은 아닙니다. 실제 외관의 이동 완료까지 촬영해 대조한 시험은 아닙니다.

예약은 허브의 영구 필드에 만료 시각을 저장합니다. 30분~24시간 목록과 개별 취소를 제공하고 앱의 취소 상태는 `none`입니다. 본체의 사용자 설정에서 1시간→2, 2시간→4를 읽었고 설정·취소 POST와 GET도 시험했으나, `OnTimer_0` 취소 직후 사용자의 외부 조작 없이 전원이 켜졌습니다. 전원 Off로 복원한 뒤 본체 예약 쓰기를 모두 제거했습니다. 현재 설정·취소는 LAN 요청 없이 반영하며 만료 때 검증된 전원 작업 큐에 한 번만 명령을 넣습니다. 미래 예약은 재시작 때 복구하고 중단 중 지난 예약은 실행하지 않습니다. 허브에서 1시간 예약 설정·즉시 취소와 전원 Off 유지를 확인했습니다. 실제 만료까지 기다리는 전원 시험은 하지 않았으며 허브가 실행 중이어야 합니다. 시각 직접 입력·요일·반복 예약은 구현하지 않았습니다.

라이팅 4단계는 본인 삼성 앱 조작과 `Light_Off/Small/On/Huge`를 대조했습니다. 다른 보드의 Light 반전 대응은 이 모델에 적용하지 않습니다. 음성선택 5단계도 사용자 조작에서 `Volume_33/66/100/Melody/Mute`를 확인했습니다. 화면 끄기의 On은 화면 끄기 옵션이 활성화됐다는 뜻입니다. `Display_On/Off`를 사용자 조작으로 대조했습니다. 스피드·정음은 참고 구현의 Comode 슬롯을 사용하고 무풍과 동시 상태를 만들지 않습니다. 활성 수면을 지우거나 전원·모드를 자동 변경하지 않습니다. 사용자가 현재 운전을 켜기 어렵다고 해 실제 스피드·정음 운전 시험은 남겼습니다.

## IP 입력 없는 검색과 추가

드라이버 시작 시 한 번 검색하고, SmartThings 앱 검색 중에는 검색 취소 여부를 확인하며 반복합니다. IPv4 `224.0.1.187:5683`에 NON GET `/oic/res?rt=oic.d.airconditioner`를 보내고 5초 동안 응답을 모읍니다. 허브 SDK에서 지원하지 않는 `ip-multicast-ttl` 옵션 호출을 제거하고 기본 TTL을 사용합니다. IP 대역을 순서대로 훑지 않으며, 같은 LAN의 검색에 응답한 주소만 확인합니다.

응답 토큰과 에어컨 링크를 검사한 뒤 해당 송신 주소에 `/oic/d`, 필터된 `/oic/res`, `/oic/p`를 GET합니다. 제조사 `Samsung Electronics`, 현재 매핑을 확인한 보드 `A20_FAC_BORA_18K`와 동적 TCP TLS 포트를 확인한 기기만 생성 대상으로 반환합니다. 모델 필드의 `|` 뒤에 붙은 추가 식별 정보는 모델명이나 공개 결과에 넣지 않습니다.

발견한 OCF ID를 DNI로 삼아 기존 기기와 등록 대기 중인 요청을 중복 생성하지 않습니다. IP는 ID별 캐시와 기기의 영구 필드에 보관합니다. 주소가 바뀌면 기존 기기를 갱신하며, 저장 주소의 공개 탐색·TCP 연결이 실패할 때 같은 ID를 다시 찾아 GET합니다. 실제 명령 전에는 기존대로 TLS 내부 ID를 대조합니다. 응답을 잃은 POST는 자동 재전송하지 않습니다.

설정의 에어컨 IP는 기본 공란이며, 등록된 기기에 수동 주소를 지정할 때만 사용합니다. 패키지 생성 도구는 `--host` 없이 실행할 수 있습니다. 이전 호출과 호환되는 선택적 `--host`는 추가 검색 후보로만 사용하며 멀티캐스트 검색을 유지합니다. 다른 모델·IPv6·라우터를 넘는 검색은 현재 범위에 없습니다.

2026-10-19 21:12 KST에 동일 Lua 검색 코드와 PC UDP 어댑터로 IP 입력 없이 실제 에어컨 `192.168.1.170`을 찾았습니다. 공개 GET 4회, 인증 자료 미사용, 열린 소켓 0개를 확인했습니다. [실제 검색 결과](observed-discovery.json)

## 명령 처리

1. 앱 입력의 명령 종류·자료형을 검사합니다. switch는 main / windfree / autoclean / purify component를 구분합니다.
2. 탐색 당시 OCF ID를 기기에 고정합니다. 새 IP의 공개 ID와 TLS 내부 ID가 모두 같아야 설정할 수 있습니다.
3. TLS 인증 후 배치를 GET하고 지원 모드·온도 범위·설정 리소스를 확인합니다.
4. 이미 목표 상태이면 POST를 생략합니다. 변경할 필드 하나만 CBOR로 인코딩해 전송합니다. Content-Format과 Accept는 공개 구현과 같은 `application/cbor`(60)입니다.
5. 2.xx 응답 뒤 최대 세 번 배치를 GET하며 관측한 상태만 이벤트로 발행합니다. 추가 두 조회 사이에는 각각 1초를 둡니다. 목표와 일치할 때만 `AC_COMMAND_CONFIRMED`로 기록합니다.
6. 값이 일치하지 않으면 `AC_COMMAND_UNCONFIRMED`, 응답 유실은 `AC_COMMAND_UNCERTAIN`으로 남깁니다. 응답 유실 뒤에는 새 연결에서 GET하며 POST를 자동 재전송하지 않습니다.

장비별 활성 작업은 하나입니다. 설정은 입력 순서대로, refresh는 병합합니다. 대기 설정은 최대 32개이며 초과 요청은 거부합니다. 제거·재초기화 시 타이머·소켓을 닫고 늦은 이벤트를 차단합니다. 주기 조회는 기본 On, 10초이며 5~900초 범위입니다. 기존 저장된 60초 기본값 대신 새 `refreshSeconds` 설정을 사용합니다. 활성 인증 연결에서는 UDP 탐색을 생략하고 TLS 내부 ID를 계속 확인합니다. 명시적 POST 거부와 지원 범위 오류는 관측 상태를 발행하며 ONLINE을 유지합니다.

같은 값은 300초 동안 다시 발행하지 않고 발행 간격은 최소 0.25초입니다. 수동 새로고침은 전체 상태를 다시 보냅니다. 라이팅·음성·예약·패널은 값 비교를 통과한 이벤트를 `state_change=true`로 보냅니다. 효과음 `melody`를 보낸 로그가 있는데 서버에는 이전 `mute`가 남아 있었고, 전송 순서만 바꿔도 같았습니다. 명시적 변경 이벤트를 보낸 뒤 서버의 `melody` 갱신을 확인했습니다. 허브·클라우드 내부의 최초 누락 원인은 확정하지 않았습니다. SDK의 main `emit_event` 래퍼는 반환값을 버리므로 반환값 검사는 `emit_component_event`에서 수행합니다.

허브에서 제공하는 IPv4 주소로 임시 TCP 포트에 내부 연결을 만들고, 준비한 TLS ClientHello를 기기 연결 직후 전달합니다. 임시 수신 포트는 허브 자신의 주소에서 온 연결만 받습니다. 에어컨이 먼저 ClientHello를 보낸 충돌만 CoAP 전송 전 최대 6회 다시 연결합니다. 인증서 검증 실패는 이 조건에 해당하지 않습니다. 인증된 연결은 다음 조회·설정에서 재사용하며, 유휴 중 닫혔다면 POST 전의 조회만 새 연결에서 다시 수행합니다. POST를 시도한 뒤의 오류에는 연결 재사용 복구를 적용하지 않습니다.

## 검증과 남은 항목

- Lua 5.3 검사 90개 통과: 기존 제어·예약 경계 외에 운전 카드의 모드·온도·풍량 연결과 상태 발행, 무풍의 전원·모드 차단, 바람문 단일 명령, 일반 선택 시 무풍 보존, 본체 화면 토글 반전을 포함합니다.
- 모사 SDK 이벤트 294개가 표준/custom capability 스키마를 통과했습니다. version 1 응답을 `tests/fixtures/capabilities/`에 저장합니다.
- 기존 Python 검사 17개가 통과했습니다. 읽기 15개와 IP 없는 패키지 설정·선택적 검색 후보 검사 2개이며 이번 운전 카드 수정에서 해당 경로는 변경하지 않았습니다.
- CLI 2.1.1로 main capability 17개와 부가 switch component 8개·패널 doorControl component 1개를 포함한 운영 zip을 만들고 `2026-10-20T02:25:00.101824993`의 허브 설치를 확인했습니다. 사용자 승인과 동일한 운영 개인 키를 재사용하며 키 포함 zip은 비공개 디렉터리에 보관합니다. 초기 키 없는 형식 검사 zip과 구분합니다.
- 수정한 Lua의 PC 실기 GET을 2026-10-19 20:56 KST에 다시 확인했습니다. 현재 25℃, 설정 24℃, 습도 63%, 전원 Off / 모드 Auto였습니다. 공개·TLS 내부 ID가 일치했고 임시 키 삭제·열린 소켓 0개를 확인했습니다. [결과](observed-control-read.json)

공개 PC 도구 `tools/lua_pc_probe.py`는 GET·CSM만 허용합니다. 별도의 비공개 진단으로 AI 옵션 설정·복원과 예약 취소를 시험했고, 허브 시험과는 구분해 최신 기록에 남깁니다. 기능별 실기 확인·복원 범위와 장시간 미검증을 함께 봐야 합니다. 운영 인증 자료는 사용자 요청에 따른 36,500일 유효기간이며 이번 설치본은 2126-09-25까지 유효합니다. 임시 PC 조회 도구의 기본 인증서는 1일입니다.

허브에서 비지원 `ip-multicast-ttl` 옵션을 호출해 검색이 중단되는 문제를 확인하고 제거했습니다. 수정 후 실제 멀티캐스트 검색과 기기 생성이 성공했으며 사용자가 앱 추가를 확인했습니다. 주소 변경 복구·중복 생성 방지는 모사 검사 결과이고 실제 DHCP 변경은 미검증입니다. 최신 허브 결과는 [허브 관측 기록](observed-hub.json)을 기준으로 봅니다.

TLS 진단에서는 공식 SSL 설정·인증서 형식과 cosock 호출을 대조했습니다. 직접 연결의 `unexpected message`를 조사하다 TCP 연결 직후 에어컨이 먼저 ClientHello를 보내는 경우를 확인했습니다. 기기 연결을 먼저 열던 내부 중계는 같은 충돌로 실패했고, 허브의 ClientHello를 먼저 준비한 경로에서 인증 GET이 성공했습니다. 연결 재사용 전 중간 버전은 5회 중 4회 성공했습니다. 연결 재사용 버전 `2026-10-19T13:54:37.400646532`는 5회 모두 GET에 성공했습니다. 이후 기능 추가 버전에서 조회 실패 한 번과 다음 주기의 ONLINE 복구를 관측했습니다. 최신 기능 설치본의 새로고침 2회도 성공했지만 간헐 실패가 완전히 해결됐다는 근거는 아닙니다. PC에서 TLS 역할을 서버로 바꾸는 별도 시험은 동일 자체서명 인증서에 대한 `unknown_ca`로 실패했습니다. 에어컨이 ClientHello를 시작하는 펌웨어 내부 조건은 확정하지 않았고 SDK 결함으로 단정하지 않습니다.

메뉴 업데이트 후 설치된 기기의 프로필 presentation에서 상세 항목 23개, 운전 카드의 모드 선택·온도 슬라이더·풍량 선택, 무풍·청정 토글, 바람문 선택 메뉴, 두 예약 메뉴와 6개 활성 조건을 확인했습니다. 기존 표준 모드·온도·풍량 카드는 상세 화면 정의에서 제외됐고 루틴용 capability는 유지됐습니다. 새 메뉴 상태와 기존 capability·component 상태가 일치했고 ONLINE, 전원 Off, 청정 모드, 효과음, 예약 없음이 유지됐습니다. 이번 검증에서 본체 제어 명령은 보내지 않았습니다. 스마트폰의 실제 카드 모양과 비활성 렌더링은 미검증이며 서버 정의 확인을 앱 화면 갱신 완료로 취급하지 않습니다.

로컬 재현:

```bash
.venv/bin/pip install -r requirements-lua-pc.txt
.venv/bin/python tools/run_lua_tests.py
.venv/bin/python -m unittest discover -s tests -v

# 인증서나 대상 IP 없이 같은 LAN에서 공개 OCF 검색
.venv/bin/python tools/lua_discovery_probe.py --output private-diagnostics/discovery.json
```

## 근거

- [삼성 청소용 바람문 열림 안내](https://www.samsungsvc.co.kr/solution/28067): 전원 Off 상태의 사용 조건. 로컬 Panel 토큰은 본인 기기의 POST·GET으로 별도 확인했습니다.
- [삼성 스마트 쾌적/자동 안내](https://www.samsungsvc.co.kr/solution/166158), [AI 쾌적과 청정 동작](https://www.samsungsvc.co.kr/solution/40795), [청정 단독·동시 운전](https://www.samsungsvc.co.kr/solution/177977).
- [공식 embedded configuration](https://developer.smartthings.com/docs/devices/configurations-and-presentations/embedded-device-configurations), [공식 프로필의 presentation patch 예제](https://github.com/SmartThingsCommunity/SmartThingsEdgeDrivers/blob/247dbadb4f1a66c74c0713c5c6f4fde69e4f859c/drivers/SmartThings/matter-lock/profiles/lock-unlatch.yml).
- [표준 capability API](https://developer.smartthings.com/docs/api/public/#operation/getCapability), [capability presentation API](https://developer.smartthings.com/docs/api/public/#operation/getCapabilityPresentation): 명령 인자·상태 속성·앱 선택 값.
- [공식 embedded device configuration](https://developer.smartthings.com/docs/devices/configurations-and-presentations/embedded-device-configurations): profile 안에 모드·온도 범위를 지정하는 방법.
- [RFC 7252](https://www.rfc-editor.org/rfc/rfc7252.html), [IANA 멀티캐스트 주소](https://www.iana.org/assignments/multicast-addresses): NON 검색과 All CoAP Nodes 주소. [LuaSocket UDP](https://lunarmodules.github.io/luasocket/udp.html), [SmartThings 소켓 API](https://developer.smartthings.com/docs/edge-device-drivers/socket.html): 임시 UDP 포트와 멀티캐스트 TTL 설정.
- [LocalThings 제어 매핑](https://github.com/mbillow/localthings/blob/363fbd5ec9d3b34982154e3ad1dca48ba0f82501/custom_components/localthings/registry/capabilities/airconditioner.py), [climate 구현](https://github.com/mbillow/localthings/blob/363fbd5ec9d3b34982154e3ad1dca48ba0f82501/custom_components/localthings/climate.py): vendor 경로·풍량·무풍·수면 보존의 근거. 해당 기기와 동일한 동작인지는 실기 쓰기로 확인해야 합니다.
