# 에어컨 표시와 로컬 설정 구현

갱신일: 2026-10-21, Asia/Seoul.

읽기 단계에서 설정 가능한 Edge 드라이버로 확장했습니다. main은 `AirConditioner` 분류와 `oic.d.airconditioner` 메타데이터를 사용합니다. 운영 패키지 업로드·v3 허브 설치·자동 추가·허브 단독 GET과 실제 POST를 확인했습니다. 기능별 과거 설정·취소·복원 범위는 [제어 기록](observed-controls-v2.json), 현재 예약 배포와 읽기 검증은 [예약 배포 기록](observed-native-timer.json), 이후 본체 쓰기 시험은 [예약 실기 기록](observed-native-timer-trial.json)을 따릅니다. [이전 기능 기록](observed-features.json)은 당시 관측을 보존한 자료이며 Gear→AI와 자동 모드의 청정 해석은 이후 폐기했습니다.

## 구현한 기능

상세 화면은 카드별로 한 종류의 조작부를 배치합니다. 사용자 Android 화면에서 한 capability의 목록·슬라이더·토글이 별도 카드로 나뉘고 같은 그룹 제목이 반복되는 것을 확인했습니다. 이전에 설명한 ‘운전 세 항목이 한 카드에 표시된다’는 동작은 해당 앱에서 성립하지 않았습니다. 운전의 모드·풍량 목록과 희망 온도 슬라이더, 바람 설정의 옵션·바람문 목록과 무풍·청정 토글, 기기 설정의 라이팅·음성 목록과 본체 화면 토글, 자동청소 스위치와 청소용 패널 목록을 각각 구분합니다.

분리한 화면은 `samsungAcLocalOperating`, `samsungAcLocalTemperature`, `samsungAcLocalAirFeatures`, `samsungAcLocalDisplay`, `samsungAcLocalPanel`을 사용합니다. 기존 capability와 component 및 루틴 구성은 유지하고, 상세 화면에는 같은 조작부를 한 번만 배치합니다. 새 카드의 명령은 기존 검증·작업 큐로 전달하며 같은 관측값을 표시합니다. 활성 조건에 필요한 속성은 해당 카드를 소유한 capability에도 발행합니다. 기존 운전 정의에 추가한 속성이 허브에 반영되지 않아 이벤트 생성이 실패했던 것을 확인했으며, 기존 정의를 복구하고 새 운전 capability에 활성 조건을 두었습니다. 생성 원본은 `tools/build_menu_capabilities.py`이고 JSON 정의·표시·테스트 스키마를 함께 생성합니다.

그룹 제목은 `capabilities/translations/`의 `*-ko.json`과 기본 언어용 `*-en.json`에 같은 한글 `label`로 관리합니다. 이 드라이버는 메뉴 문구를 한글로 제공하므로 앱이 언어를 지정하지 않아도 같은 제목을 사용합니다. `Samsung AC Local` 접두사를 빼고 ‘운전’, ‘희망 온도’, ‘바람 설정’, ‘무풍·청정’, ‘예약’, ‘기기 설정’, ‘본체 화면’, ‘자동청소’, ‘청소용 패널’로 표시하며, 루틴 호환용 기존 설정 그룹은 ‘라이팅·음성’으로 구분합니다. 기기 예약은 상세 화면에서 숨기고 허브 예약만 ‘예약’으로 표시합니다. 기존 등록용 capability `name`과 ID는 유지합니다. 번역 파일은 생성기와 별도로 관리하며, 대응하는 `*-presentation.json`의 ID에 `smartthings capabilities:translations:upsert <ID> --capability-version 1 --input <번역 파일>`로 등록합니다. 기존 해당 언어 번역에 다른 필드가 있으면 보존하고 `label`만 병합합니다. 방식은 [SmartThings Capability Translations 문서](https://developer.smartthings.com/docs/devices/capabilities/capability-translations)를 따릅니다.

무풍·청정·본체 화면·자동청소의 상세 표시 형식은 `switch`입니다. 사용자 휴대폰에서 기존 `toggleSwitch`가 원형으로 나타난 것을 확인한 뒤 표시 형식을 변경했습니다. 명령명·On/Off 인자·상태 매핑은 유지하며, 변경 후 사용자가 휴대폰에서 자동청소 제목과 네 가지 길쭉한 On/Off 스위치가 정상임을 확인했습니다. 표시 정의가 이미 있으면 `smartthings capabilities:presentation:update`를 사용합니다. `create`는 아직 없는 표시 정의에만 사용하며, 표시 수정에는 capability 속성 정의 갱신이 필요하지 않습니다.

기기 화면 구성 원본은 `capabilities/ac-device-config.json`입니다. 그룹 번역을 등록한 뒤 `smartthings presentation:device-config:create --input capabilities/ac-device-config.json --json`으로 화면을 생성하고, 반환된 `vid`와 `mnmn`을 `driver/profiles/samsung-ac.yml`의 `metadata.vid`와 `metadata.mnmn`에 함께 연결해 패키징합니다. 방식은 [공식 Edge 화면 지정 절차](https://developer.smartthings.com/docs/devices/configurations-and-presentations/device-presentations#using-device-presentations-with-smartthings-edge-drivers)를 따릅니다. 상세 화면·루틴·대시보드의 순서, 범위, 활성 조건은 이 JSON에 보존합니다.

기존 구성과 동일한 입력으로 화면을 다시 생성했을 때 이전 영어 제목이 남은 화면 ID가 재사용됐습니다. 현재는 카드 분리를 반영한 구성으로 새 화면을 생성하고, 한국어·영어·언어 미지정 조회에서 모두 한글 그룹 제목인지 확인합니다. 각 메뉴의 표시 유형이 하나이고 제목이 서로 다른지, 이전의 모든 조작부가 한 번씩 남아 있는지, 활성 조건·루틴이 보존됐는지를 생성된 결과로 확인합니다. 스마트폰 렌더링은 서버 구성 검증과 별도로 확인합니다.

번역 등록 결과와 설치된 기기의 화면 정보는 따로 확인합니다. 이번 확인에서 동일 소스 재업로드와 프로필 메타데이터 변경만으로는 기존 Device Presentation의 영어 제목이 유지됐습니다. 자동 생성용 `deviceConfig`와 capability별 `config`를 함께 넣었을 때에는 명시한 `vid`도 적용되지 않아, 표시 설정을 위 JSON으로 분리했습니다. 구성이나 번역을 변경하면 화면을 다시 생성하고, 설치된 기기의 `presentationId`와 `manufacturerName`이 생성 결과의 두 값과 일치하는지 확인합니다. 기기 정보에 값이 없으면 임의 기본값으로 대체하지 않으며, 기기에 저장된 쌍으로 직접 화면을 조회해 한국어 그룹 제목과 기존 조작부를 대조합니다. 이름 변경에 에어컨 제어 명령은 필요하지 않습니다.

한글 화면 지정 후 앱의 연결 오류를 조사했을 때, 허브는 인증 GET을 계속 성공했지만 기기의 `manufacturerName`이 비어 있었습니다. 해당 제조사 값으로 화면을 조회하면 HTTP 422가 반환됐고 생성 당시 제조사 `SmartThingsCommunity`로 조회하면 정상 응답했습니다. 이전 검증은 생성 결과의 제조사를 대신 사용해 이 누락을 놓쳤습니다. 프로필에 `mnmn`을 명시하고 실제 기기 정보의 두 값을 검증하도록 수정했습니다. 휴대폰 화면의 복구 여부는 이 API 검증과 별도로 확인합니다.

바람문은 닫힘·상단만·하단만·상하단 중 하나를 선택해 `Blooming`을 한 번만 전송합니다. 운전 옵션은 일반·스피드·정음이며 무풍과 청정은 별도 On/Off 토글입니다. ‘일반’은 스피드·정음만 해제하고 이미 켠 무풍은 유지합니다. 본체 화면의 켜짐은 기존 화면 끄기 옵션의 해제(`Display_Off`)를 뜻합니다. 청소용 패널은 운전용 바람문과 구분합니다. 허브 예약 취소는 각 메뉴의 ‘예약 없음 (취소)’로 합치며 기존 취소 명령은 루틴에서 유지합니다. 본체 예약에는 취소 명령을 노출하지 않습니다.

### 같은 값 재선택의 응답

사용자가 같은 목록 값을 선택하면 로딩 후 네트워크·서버 오류가 나타난다고 보고했습니다. 기존 전송 계층은 새 GET에서 목표 상태와 같으면 POST를 생략하지만, 발행 계층도 최근 300초 안의 동일 값 이벤트를 생략했습니다. 새 회귀 검사는 기존 코드에서 실패하고 수정본에서 통과했습니다.

명령 뒤에는 그 명령에 대응하는 상태 속성만 중복 억제에서 제외하고 `state_change=true`로 발행합니다. 표준 capability와 기존·현재 메뉴의 대응 속성을 모두 포함합니다. 값은 확인 GET에서 만들며 요청 인자를 성공 상태로 대신 발행하지 않습니다. 허브 예약은 본체 GET 없이 저장된 예약 상태를 같은 방식으로 응답합니다. 일반 주기 조회의 동일 값 억제와 초당 4개 전송 간격은 유지합니다. 관련 계약은 [공식 Edge 이벤트 문서](https://developer.smartthings.com/docs/edge-device-drivers/capabilities.html#state-change)에 있습니다.

`2026-10-20T15:24:15.33648447`을 설치한 뒤 2026-10-21 00:25 KST에 음성선택 2회, 라이팅·모드·바람문·패널 각각 1회, 허브 켜짐·꺼짐 예약 없음 각각 1회를 호출했습니다. 8회 모두 서버의 같은 값 상태에 새 타임스탬프가 수신됐습니다. 허브 로그는 본체 설정 6회 모두 `AC_COMMAND_UNCHANGED`, 본체 POST 0회, 조회·이벤트·명령 오류 0회였습니다. 전원 Off·본체 및 허브 예약 없음·ONLINE을 유지했습니다. 휴대폰에서 로딩 종료가 보이는지는 이 서버·허브 검사와 구분합니다.

이번 화면은 상세 행 23개, 메뉴 제목 9개이며 기기 예약 2개 행만 제외했습니다. 나머지 상세 행, 길쭉한 스위치 4개, 활성 조건 6개, 기존 대시보드와 루틴 구성은 이전 생성 결과와 같습니다. 실제 기기에 저장된 화면 ID·제조사 쌍으로 `ko`, `ko-KR`, `en`, 언어 미지정 조회를 수행해 ‘예약’ 제목을 확인했습니다. Lua 검사 96개·스키마 이벤트 491개·Python 검사 21개와 [실기 기록](observed-selection-ack.json)에 확인 범위를 보존합니다.

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
| 허브 켜짐·꺼짐 예약 | `instantcommon43059.samsungAcLocalTimer` / main | 허브에 시각 저장. 만료 때 전원 명령 한 번. 설정·취소는 본체에 쓰지 않음 |
| 본체 켜짐·꺼짐 예약 | `instantcommon43059.samsungAcLocalNativeTimer` / main | `OnTimer_N` / `OffTimer_N`, N=1~48. 1은 30분. 본체 GET으로 표시하며 취소는 미지원 |
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

‘허브 예약’은 허브의 영구 필드에 만료 시각을 저장합니다. 30분~24시간 목록과 개별 취소를 제공하고 앱의 취소 상태는 `none`입니다. 본체의 사용자 설정에서 1시간→2, 2시간→4를 읽었고 설정·취소 POST와 GET도 시험했으나, `OnTimer_0` 취소 직후 사용자의 외부 조작 없이 전원이 켜졌습니다. 당시 전원 Off로 복원한 뒤 본체 예약 쓰기를 모두 제거했습니다. 허브 예약의 설정·취소는 LAN 요청 없이 반영하며 만료 때 전원 작업 큐에 한 번만 명령을 넣습니다. 미래 예약은 재시작 때 복구하고 중단 중 지난 예약은 실행하지 않습니다. 2026-10-20 사용자가 선택한 30분 꺼짐 예약도 허브에만 있었으며, 21:13 KST 본체 GET은 `OffTimer_0`을 반환했습니다. 이후 21:39:49 전원 꺼짐과 예약 없음 상태가 기록됐습니다. 21:09:46의 30분 허브 예약 상태에서 약 30분이 지났으므로 허브 예약 실행으로 판단하지만, 당시 실행 로그는 확보하지 못했습니다.

현재 설치본은 별도 `NativeTimer` capability에서 본체 예약의 양수 설정과 조회를 연결합니다. 30분은 `OffTimer_1` 또는 `OnTimer_1` 하나만 `/mode/vs/0`에 POST하고, 기존 인증·신원 검사와 확인 GET을 재사용합니다. 입력 0·음수·분수·범위 초과를 거부하며, 본체 예약 상태가 없는 응답에서는 설정하지 않습니다. 같은 시간을 다시 선택하면 POST를 생략하지 않되, 같은 값의 GET만으로 시작 시각 갱신까지 확인할 수 없어 결과를 `accepted`로 구분합니다. 응답 유실 뒤 POST는 반복하지 않습니다.

본체 표시에는 GET에서 읽은 값만 사용합니다. 누락은 `unknown`(확인 안 됨), 실제 0은 `none`(예약 없음)으로 구분하며 허브의 남은 시간이나 명령 인자로 대신하지 않습니다. 목록은 기기 응답의 시간 값을 표시하며 별도 초 단위 카운트다운을 만들지 않습니다. 본체 예약에서 ‘예약 없음’은 읽기 상태이며 취소 선택지는 없습니다. 취소는 본체·리모컨을 사용해야 합니다. 기존 허브 예약의 ID·저장값·취소·재시작 복구는 보존하고, 서로 다른 예약을 자동으로 옮기거나 취소하지 않습니다. 시각 직접 입력·요일·반복 예약은 구현하지 않았습니다.

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

- Lua 5.3 검사 93개 통과: 기존 제어·예약 경계와 본체 예약의 단일 POST, 0 차단, 재설정, GET 확인, 응답 유실, 허브 예약과의 상태 분리를 포함합니다.
- 모사 SDK 이벤트 317개가 표준/custom capability 스키마를 통과했습니다. 기존 API 응답과 새 capability의 로컬 정의를 `tests/fixtures/capabilities/`에 저장합니다.
- Python 검사 21개가 통과했습니다. 읽기·패키지 검사 17개와 화면 검사 4개입니다. 새 검사는 본체 예약에서 취소 명령·0이 노출되지 않고 누락·예약 없음을 구분하는지 확인합니다. 이전 화면 수정에서는 제목 중복, `toggleSwitch` 복귀, On/Off 인자 뒤바뀜, 활성 조건 삭제, 기존 운전 정의에 새 속성 삽입을 각각 주입했을 때 회귀 검사가 모두 실패하는 것도 확인했습니다.
- CLI 2.1.1로 main capability 17개와 부가 switch component 8개·패널 doorControl component 1개를 포함한 운영 zip을 만들고 `2026-10-20T02:25:00.101824993`의 허브 설치를 확인했습니다. 사용자 승인과 동일한 운영 개인 키를 재사용하며 키 포함 zip은 비공개 디렉터리에 보관합니다. 초기 키 없는 형식 검사 zip과 구분합니다.
- 수정한 Lua의 PC 실기 GET을 2026-10-19 20:56 KST에 다시 확인했습니다. 현재 25℃, 설정 24℃, 습도 63%, 전원 Off / 모드 Auto였습니다. 공개·TLS 내부 ID가 일치했고 임시 키 삭제·열린 소켓 0개를 확인했습니다. [결과](observed-control-read.json)

공개 PC 도구 `tools/lua_pc_probe.py`는 GET·CSM만 허용합니다. 별도의 비공개 진단으로 AI 옵션 설정·복원과 예약 취소를 시험했고, 허브 시험과는 구분해 최신 기록에 남깁니다. 기능별 실기 확인·복원 범위와 장시간 미검증을 함께 봐야 합니다. 운영 인증 자료는 사용자 요청에 따른 36,500일 유효기간이며 이번 설치본은 2126-09-25까지 유효합니다. 임시 PC 조회 도구의 기본 인증서는 1일입니다.

허브에서 비지원 `ip-multicast-ttl` 옵션을 호출해 검색이 중단되는 문제를 확인하고 제거했습니다. 수정 후 실제 멀티캐스트 검색과 기기 생성이 성공했으며 사용자가 앱 추가를 확인했습니다. 주소 변경 복구·중복 생성 방지는 모사 검사 결과이고 실제 DHCP 변경은 미검증입니다. 최신 허브 결과는 [허브 관측 기록](observed-hub.json)을 기준으로 봅니다.

TLS 진단에서는 공식 SSL 설정·인증서 형식과 cosock 호출을 대조했습니다. 직접 연결의 `unexpected message`를 조사하다 TCP 연결 직후 에어컨이 먼저 ClientHello를 보내는 경우를 확인했습니다. 기기 연결을 먼저 열던 내부 중계는 같은 충돌로 실패했고, 허브의 ClientHello를 먼저 준비한 경로에서 인증 GET이 성공했습니다. 연결 재사용 전 중간 버전은 5회 중 4회 성공했습니다. 연결 재사용 버전 `2026-10-19T13:54:37.400646532`는 5회 모두 GET에 성공했습니다. 이후 기능 추가 버전에서 조회 실패 한 번과 다음 주기의 ONLINE 복구를 관측했습니다. 최신 기능 설치본의 새로고침 2회도 성공했지만 간헐 실패가 완전히 해결됐다는 근거는 아닙니다. PC에서 TLS 역할을 서버로 바꾸는 별도 시험은 동일 자체서명 인증서에 대한 `unknown_ca`로 실패했습니다. 에어컨이 ClientHello를 시작하는 펌웨어 내부 조건은 확정하지 않았고 SDK 결함으로 단정하지 않습니다.

카드 제목·스위치 수정본 `2026-10-20T11:09:52.861719186`을 허브에 설치했습니다. 실제 기기의 `presentationId`·`manufacturerName`으로 조회한 화면에서 서로 다른 메뉴 제목 9개, 상세 항목 23개와 6개 활성 조건을 확인했습니다. `ko`, `ko-KR`, `en`, 언어 미지정 모두 한글 제목이며, 카드별 표시 유형은 하나이며 무풍·청정·본체 화면·자동청소 4개 항목은 `switch`입니다. 새 카드와 이전 카드의 조작부·입력 범위·활성 조건을 대조했고 기존 루틴·대시보드 구성이 보존됐습니다. 새 카드의 상태가 기존 capability 관측값과 일치하고 ONLINE·예약 없음도 확인했습니다. 수정본의 24초 허브 로그에는 조회 성공 5회, 조회 실패·이벤트 생성 오류·제어 명령 0회가 기록됐습니다. 이번 검증에서 본체 제어 명령은 보내지 않았습니다. 사용자가 앱을 다시 연 뒤 자동청소 제목과 무풍·청정·본체 화면·자동청소의 길쭉한 On/Off 스위치가 정상임을 확인했습니다. 운전 조건별 비활성 렌더링과 실물 제어는 이번 화면 수정 검증에 포함하지 않았습니다.

본체 예약 수정본 `2026-10-20T12:52:02.622985997`의 허브 설치를 확인했습니다. 새 `NativeTimer` 화면의 최초 전체 생성은 `403 Forbidden`이었으나, 최소 상태 화면 생성 후 전체 표시 정의 갱신이 성공했습니다. 오류의 내부 원인은 확정하지 않았습니다. 한글 번역 등록, Device Presentation 생성, 프로필의 `vid`·`mnmn` 연결 후 설치된 기기의 실제 두 값으로 화면을 조회했습니다. `ko`, `ko-KR`, `en`, 언어 미지정에서 10개 제목·25개 상세 항목, 기존 스위치 4개·활성 조건 6개를 확인했습니다. 본체 예약 두 항목을 제외한 기존 조작부·루틴·대시보드는 이전 화면과 같습니다.

설치 후 28초 허브 로그에서 GET 성공 5회, 조회 실패·이벤트 오류·제어 명령 0회를 확인했습니다. 허브 GET의 본체 예약 두 개 모두 0, 전원 Off와 앱 서버의 기기·허브 예약 모두 `none`, ONLINE을 대조했습니다. 최초 조회에서는 새 속성 값이 아직 없었으나 이벤트 전송 후 값이 수신됐습니다. 이 배포 직후 검증에서는 실제 전원·예약 명령을 보내지 않았으며, 당시 양수 예약 수락·만료와 휴대폰 렌더링은 미검증이었습니다. 식별자와 인증 자료를 제외한 당시 결과는 [예약 배포 기록](observed-native-timer.json)에 보존합니다. 이후 양수 예약 수락과 0 전송 시험은 다음 기록으로 구분합니다.

### 본체 예약 설정과 취소 비교

2026-10-20 22:01~22:16 KST에 같은 설치본에서 후속 실기 시험을 했습니다. 사용자가 승인한 범위에서 설치된 허브의 `setOnDelay("1")`·`setOffDelay("1")`을 각각 호출했고, `AC_COMMAND_CONFIRMED`와 본체 GET의 해당 타이머 1, 앱 서버의 본체 예약 상태 1을 확인했습니다. 기존 허브 예약은 두 항목 모두 `none`을 유지했습니다. 실제 30분 만료까지 기다린 시험은 아닙니다.

운영 드라이버의 0 차단을 유지한 채 별도 PC 진단에서 `OnTimer_0`·`OffTimer_0`을 각각 한 번씩 전송했습니다. 두 요청 모두 `2.04 Changed`였으며, 먼저 본체 GET의 시간이 1에서 0으로 바뀐 후 수초 뒤 전원이 각각 Off→On, On→Off로 바뀌었습니다. 따라서 2.xx 응답과 타이머 0 확인만으로 안전한 취소 성공이라고 판정하면 안 됩니다. 0을 '즉시 실행'으로 처리한다는 해석은 두 전원 변화에 근거한 높은 확신의 추론이며, 펌웨어 내부 처리는 확인하지 못했습니다.

이 시험 중 자동청소 설정이 On으로 바뀌어 기존 Off를 한 번 전송해 복원했습니다. 이후 전원 Off, 두 타이머 0, Cool·Comode_Off·Blooming_0·ComfortAICooling_Off·Autoclean_Off·Panel_Close가 기록한 시작 상태와 일치했습니다. 설정 온도 등 이 기록에 포함하지 않은 모든 필드가 복원됐다고 확대하지 않습니다.

0 없는 취소 후보로는 전원 Off·OffTimer_1 상태에서 `/power/vs/0`에 같은 전원 Off만 한 번 재전송했습니다. `2.04 Changed`를 받았지만 세 번의 확인 GET에서 전원 Off·OffTimer_1이 유지되어 이 조건에서는 취소되지 않았습니다. 이후 사용자가 리모컨으로 취소했습니다. 42개의 모드·설정 GET 기록에서 첫 `OffTimer_1`이 `OffTimer_0`으로 바뀌었고 다른 모드 옵션·설정 값의 차이는 없었습니다. 별도 최종 GET에서 전원 Off·두 타이머 0을 확인했습니다.

비교 출력의 `removed`·`added`는 진단 도구가 두 응답의 차이를 계산한 표현이며 실제 응답이나 취소 명령 필드가 아닙니다. 0 쓰기 시험에서도 같은 1→0 변화가 전원 변경 전에 나타났으므로 이 차이만으로 리모컨의 취소 명령을 재구성할 수 없습니다. 전체 옵션을 읽어서 1을 빼고 0을 넣어 다시 보내는 방식도 검증된 취소 방법이 아닙니다. 공개 [LocalAppliances 옵션 병합 구현](https://github.com/BrawnyBravo/LocalAppliances/blob/3b536125c371b2b21a02d6b28f79472d155f3397/custom_components/localthings/registry/capabilities/common.py#L179)은 옵션 이름별 치환을 설명하며, [OCF 규격 §12.2.3](https://openconnectivity.org/specs/OCF_Core_Specification_v2.0.5.pdf)은 POST를 속성 갱신, DELETE를 자원 삭제로 정의합니다. 임의의 삭제 요청을 예약 취소로 보내지 않습니다.

공개 [삼성 IR 구현](https://github.com/crankyoldgit/IRremoteESP8266/blob/master/src/ir_Samsung.cpp)에는 예약 시간과 활성화 비트가 따로 있습니다. 다만 이 기기의 리모컨 신호와 같은 규격인지, 해당 비트가 OCF에서 어떤 명령으로 대응되는지는 미확인입니다. 기기의 모드·설정 조회와 조사한 공개 구현에서는 별도 취소 명령을 찾지 못했습니다. 이는 취소 경로가 없다는 증명이 아니며, 0 이외의 임의 토큰을 취소 기능으로 구현하지 않습니다. 남은 확인 대상은 이 보드의 취소 명령 형식 또는 예약 활성화 필드입니다.

현재 확인 범위는 양수 1의 설정 수락과 본체 조회, 0의 전원 부작용, 동일 전원 Off 재전송 실패, 리모컨 취소 후 상태입니다. 전체 1~48 값, 같은 시간 재설정의 실제 만료 시각, 30분 자연 만료, 켜진 상태에서 리모컨으로 꺼짐 예약을 취소할 때의 전원 유지, 새 카드의 휴대폰 렌더링은 이번 시험에 포함하지 않았습니다. 원문 식별자·인증 자료를 제외한 시간순 결과는 [예약 실기 기록](observed-native-timer-trial.json)에 보관합니다.

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
