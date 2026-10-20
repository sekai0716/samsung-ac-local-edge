# 실제 장비의 조회 항목과 Edge 반영 설계

대상은 `A20_FAC_BORA_18K / TizenRT2.0`입니다. 이 문서는 초기 전체 조회와 후보 설계의 기록이며 근거는 [observed-resources.json](observed-resources.json)입니다. 조회 시작 시각은 2026-10-19 19:57:51 KST입니다. 순차 조회이므로 모든 값이 같은 순간의 측정값은 아닙니다. 이후 확정한 AI·공기질·라이팅·음성 매핑과 허브 예약으로 바꾼 현재 구현은 [설정 안내](control.md)와 [최신 실기 기록](observed-controls-v2.json)을 따릅니다.

## 1. 조회 범위와 결과

인증된 `/oic/res` 전체 디렉터리 GET은 `2.05`, 8,970바이트였습니다. `/device/0` 배치에 있는 22개 경로와 대조한 뒤, 디렉터리까지 포함한 상태·설정·진단용 정적 경로 65개를 각각 GET했습니다.

| 구분 | 결과 |
|---|---|
| 디렉터리와 배치의 고유 경로 | 76개 |
| 개별 상태 GET 시도 | 65개 |
| `2.05` 성공 | 59개. 이 중 19개는 실제 빈 응답 |
| `5.00` 서버 오류 | `/bixby/0`, `/bixby/1` |
| `4.05` GET 불허 | `/file/transfer/chunk/vs/0`, `/file/transfer/chunk/vs/1` |
| `4.04` 경로 없음 | `/hass/command/vs/0`, `/hass/command/vs/1` |
| 상태 조회 범위 밖 | 장비 정보·보안·등록·네트워크 관련 11개 경로 |

범위 밖 11개는 `/oic/d`, `/oic/p`, `/oic/sec/doxm`, `/oic/sec/pstat`, `/CoapCloudConfResURI`, `/DevConfResURI`, `/EasySetupResURI`, `/WiFiConfResURI`, `/sec/accesspointlist`, `/sec/devices`, `/sec/provisioninginfo`입니다. `/oic/d`와 `/oic/p`는 기본 식별 단계에서 별도로 읽었으며 DOXM 광고 메타데이터는 포트 탐색에 사용했습니다. 이 11개를 모두 미조회한 것으로 해석하지 않습니다.

시험 시 전원은 Off, `AirMonitoring`은 Off였습니다. 측정 시작·자가진단 시작·전원·온도·예약·등록을 변경하는 명령은 보내지 않았습니다. 서버 CA 체인과 공개/암호화 경로의 장비 식별자를 검증했고 임시 키 삭제를 확인했습니다. 광고되지 않은 경로의 추측 탐색은 수행하지 않았습니다.

성공 코드, 실제 빈 값, 필터링으로 저장하지 않은 값, 오류를 구분합니다. 예를 들어 `/information/vs/0`의 저장 값 `{}`는 기기의 빈 응답이 아니라 식별 정보 제외의 결과입니다. `5.00`은 이번 GET의 서버 오류이며 영구 미지원으로 단정하지 않습니다.

## 2. 센서와 전력

이 표의 수치는 기기가 보고한 값입니다. 센서 정확도, 갱신 간격, 전원 Off 상태에서의 최신성은 아직 확인하지 않았습니다.

| 항목 | 실제 읽은 값 | Edge 반영 제안과 제한 |
|---|---|---|
| 실내 온도 | 25℃ | `temperatureMeasurement` |
| 설정 온도 | 24℃, 광고 범위 18~30℃ | `thermostatCoolingSetpoint`. 쓰기·설정 간격은 미검증 |
| 습도 | vendor `fivepercentHumidity="63"` | `relativeHumidityMeasurement`, 63%. 일반 습도 0보다 전용 필드 우선 |
| 미세먼지 `Dust` | `["5.000000", "0.000000"]` | PM10 후보 → `dustSensor.dustLevel` |
| 초미세먼지 `FineDust` | `["5.000000", "0.000000"]` | PM2.5 후보 → `fineDustSensor.fineDustLevel` |
| 극초미세먼지 `SuperFineDust` | `["5.000000", "0.000000"]` | PM1 후보 → `veryFineDustSensor.veryFineDustLevel` |
| 종합 공기 상태 `CleanLevel` | `1.000000` | 원시 등급. 좋음/나쁨이나 표준 AQI로 임의 변환하지 않음 |
| 냄새 `Odor` | `0.000000` | `odorSensor.odorLevel` 후보. 0만으로 센서 동작·공기 상태를 판정하지 않음 |
| 순간 전력 `instantaneousPower` | `0.000000` | `powerMeter` 후보. 전원 Off에서 0 조회, 운전 중 값·단위 검증은 남음 |
| 누적 전력량 `cumulativePower` | `275852400` | `energyMeter` 후보. kWh 환산 확정 전에는 진단 원시값으로 보관 |
| 별도 소비 필드 `cumulativeConsumption` | `100.000000` | 의미·단위 미확정. 누적 전력량과 합산하지 않음 |
| 사용 임계값 `usageThreshold` | `0.000000` | 원시 설정값. 요금·사용량으로 해석하지 않음 |
| 표준 전력 자원 | `power=0.0`, `energy=100.0` | vendor 자원과 중복·상이한 의미 가능. 두 계량값을 중복 집계하지 않음 |

먼지 3종의 이름·첫 번째 배열 값·µg/m³ 단위 매핑은 [LocalThings 에어컨 센서 정의](https://github.com/mbillow/localthings/blob/363fbd5ec9d3b34982154e3ad1dca48ba0f82501/custom_components/localthings/registry/capabilities/airconditioner.py)에 근거한 후보입니다. 해당 소스도 항목 존재만으로 실제 센서의 유효성을 보장하지 않습니다. 두 번째 배열 값은 참고 구현이 기기 자체 등급으로 해석하므로 농도와 합치거나 표준 AQI로 사용하지 않습니다. 이번 장비의 단위·정확도는 삼성 앱 및 독립 센서와 대조해야 합니다.

숫자는 `"5.000000"`처럼 문자열 소수로 옵니다. 유한한 수로 파싱하고 범위를 검사한 뒤 capability 형식에 맞춥니다. 문자열에 바로 `int()`를 적용해 누락시키지 않습니다. 습도는 0~100 범위를 검사하며 필드 이름만 보고 5% 단위로 반올림하지 않습니다. 이번 센서 목록에는 CO₂·VOC 항목이 없었습니다. 이를 하드웨어 부재로 확대하지 않습니다.

위 stock capability 이름과 미세먼지 속성·단위는 [SmartThings 공식 capability 목록](https://developer.smartthings.com/docs/devices/capabilities/capabilities-reference)을 확인했습니다. 실제 profile·presentation과 앱 표시는 아직 구현하지 않았습니다.

### 누적 전력량의 환산과 통계

참고 구현은 `/airflow/vs/0`이 있고 `/wind/strength/vs/0`이 없는 보드를 legacy로 분류하고 `cumulativePower / 100000`을 kWh로 사용합니다. 이번 장비도 이 리소스 구조를 갖습니다. 따라서 **2,758.524 kWh, 표시값 약 2,758.52 kWh는 중간 확신도의 환산 후보**이며 실제 kWh 확인값은 아닙니다. 같은 시점의 삼성 앱 누적 수치 또는 일정 운전 구간의 독립 전력계 증분으로 단위를 확정합니다. 근거는 [legacy 변환](https://github.com/mbillow/localthings/blob/363fbd5ec9d3b34982154e3ad1dca48ba0f82501/custom_components/localthings/registry/capabilities/airconditioner.py)과 [공통 전력 처리](https://github.com/mbillow/localthings/blob/363fbd5ec9d3b34982154e3ad1dca48ba0f82501/custom_components/localthings/registry/capabilities/common.py)입니다.

설계에서는 원시 카운터와 단위 검증 상태를 분리합니다. 환산 확정 후에만 `energyMeter` 이벤트를 발행합니다. 전력의 `65278`은 참고 구현이 FAC_BORA 계열에서 미측정 값으로 처리하는 값이므로 후보 예외 규칙으로 기록합니다. 이번 조회에서는 이 값이 나오지 않았습니다. 통신 실패·일시적 0·음수로 누적 계량값을 초기화하거나 평생 사용량을 중복 가산하지 않습니다.

이번 응답에는 당일·이번 달·지난달 전력량 필드가 없었습니다. 해당 통계가 필요하면 검증된 누적값의 차분과 한국 시간의 기간 경계를 사용하는 별도 집계로 설계합니다. 기준값이 없는 기간, 카운터 감소, 단절 구간은 구분해 표시하고 요금으로 자동 환산하지 않습니다. 두 번째 인덱스와 공유 계량값의 중복 합산도 금지합니다.

SmartThings Energy 연동은 `energyMeter` 카드와 별도 단계입니다. 공식 `powerConsumptionReport` 문서는 15분마다의 사용량 보고와 사용자 정의 드라이버의 계산 구현을 요구합니다. 이 요구와 앱 반영 여부를 따로 검증하며 현재 지원 완료로 표시하지 않습니다. [공식 설명](https://developer.smartthings.com/docs/devices/capabilities/capabilities-reference#powerconsumptionreport)

## 3. 추가 설정·알람·소모품

`/mode/vs/0`에는 옵션 접두어 37종이 있었고, 식별 정보 등을 제외한 34개 원시 옵션을 저장했습니다. 아래는 모두 **읽기 확인**이며 쓰기 지원표가 아닙니다.

| 구분 | 실제 토큰 | 반영 방침 |
|---|---|---|
| 무풍 | `Comode_Off` | 기존 무풍 후보에 반영. Nano 쓰기 미검증 |
| 취침·예약 | `Sleep_0`, `OnTimer_0`, `OffTimer_0` | 원시값 보관. 시간 단위·예약 의미 검증 후 노출 |
| 자동건조 | `Autoclean_Off`, `AutocleanProgress_1`, `StopAutoClean_Idle` | 상태 후보. 진행값 1을 근거 없이 1%로 표시하지 않음 |
| 공기 관리 | `AirMonitoring_Off`, `AirpatrolInterval_0`, `PurifiAI_Off` | 상태 후보. 센서 최신성과 연결해 검증 |
| AI 관련 | `AI_Enable`, `ArtificialWorking_Off`, `ComfortAICooling_Off`, `WelcomeCoolingState_Off` | 원시 설정 보관. 토큰 이름만으로 기능·제어 가능 여부 확정하지 않음 |
| 진단 | `DiagnosisAI_Off`, `ProgressDiagnosisAI_0`, `ResultDiagnosisAI_Normal` | 저장된 진단 상태. 이번에 자가진단을 실행한 결과는 아님 |
| 패널·표시 | `Panel_Close`, `Display_Off`, `Light_Off` | 상태 후보. 패널 작동·조명 제어는 미검증 |
| 음성·소리 | `Volume_Melody`, `VoiceSet_Enable`, `WakeupWord_4` | 원시 설정 보관. 음성 서비스 동작은 미검증 |
| 필터 관련 | `PM1Progress_67` | 원시값 67. 잔여 수명 67%로 단정하지 않음 |
| 절전·제습 | `EnergySaveIcon_Off`, `Dehumidification_0` | 원시 설정. 표시 아이콘과 실제 절전 기능을 구분 |
| 운전·기타 | `Operation_Family`, `Blooming_0`, `DurationOn_0`, `Smarton_LockOff`, `Weather_Off` | 원시 설정. `DurationOn`의 시간 단위 미확정 |
| 기능 비트맵·업데이트 | `OptionCode_925`, `ExtendOptionCode_0`, `UpdateAllow_NotAllowed` | 진단 메타데이터. 비트맵 의미·업데이트 기능 미검증 |

`ModelInfo`, `RacInfo`, `WakeupWordRange`는 접두어만 기록했습니다. 식별 정보 또는 현재 허용한 상태 형식 밖의 값을 기능 판단에 사용하지 않습니다.

`/consumable/vs/0`은 `name="FilterProgress"`, `state="2"`를 반환했습니다. 단계값 2를 잔량 2% 또는 stock `filterStatus`의 normal/replace로 임의 변환하지 않습니다. 이번 응답에는 필터 사용 시간·청소 임계 시간·실외 온도 토큰이 없었습니다.

`/alarms/vs/0`은 4개 항목을 반환했습니다. `ErrorCode_OFF`, `FilterAlarm_OFF`, `AC_V_0002_OFF`는 `Deleted`, `DA_AC_M_0004`는 `Created`였습니다. 코드·상태를 함께 보관하며 `Created` 코드의 의미를 확인하기 전까지 특정 고장으로 표시하지 않습니다. 알람 시각에는 시간대가 붙어 있지 않아 UTC로 단정하지 않습니다.

`/diagnosis/vs/0`의 `diagnosisStart="Ready"`는 상태 조회 결과입니다. 자가진단 시작은 하지 않았습니다. DRLC(전력 수요반응) 값은 level 0, override Off, duration 0, 시작 시각 1970년 기본값이었으며 사용자 절전 모드나 실제 이벤트 이력으로 사용하지 않습니다.

## 4. 모든 개별 GET 결과

아래의 `{i}`는 실제로 조회한 마지막 인덱스 0 또는 1입니다. `빈맵`은 기기가 실제로 빈 객체를 반환한 경우이며, 원시 값 보관 제외와 다릅니다.

| 경로 | 인덱스 0 | 인덱스 1 | 처리 |
|---|---|---|---|
| `/actions/vs/{i}` | 2.05 빈맵 | 2.05 빈맵 | 노출할 상태 없음 |
| `/airflow/{i}` | 2.05 값 있음 | 2.05 빈맵 | 표준 풍량·풍향 |
| `/airflow/vs/{i}` | 2.05 값 있음 | 2.05 빈맵 | vendor 풍량·풍향 |
| `/alarms/vs/{i}` | 2.05 4개 항목 | 2.05 빈맵 | 알람 진단 |
| `/bixby/{i}` | 5.00 | 5.00 | GET 서버 오류 |
| `/configuration/vs/{i}` | 2.05 | 2.05 | 지역 메타데이터 |
| `/consumable/vs/{i}` | 2.05 | 2.05 | 소모품 원시 단계 |
| `/device/{i}` | 2.05 배치 | 2.05 배치 | 응답 목록과 실제 값 분리 |
| `/diagnosis/vs/{i}` | 2.05 Ready | 2.05 빈맵 | 진단 시작 안 함 |
| `/drlc/{i}` | 2.05 | 2.05 | 전력 수요반응 기본 상태 |
| `/drlc/vs/{i}` | 2.05 | 2.05 | 위 상태의 vendor 표현 |
| `/energy/consumption/{i}` | 2.05 | 2.05 빈맵 | 표준 전력 자원 |
| `/energy/consumption/vs/{i}` | 2.05 | 2.05 빈맵 | 전력·누적 카운터 후보 |
| `/file/information/vs/{i}` | 2.05 | 2.05 | 파일 형식·시간 오프셋 메타데이터 |
| `/file/list/vs/{i}` | 2.05 | 2.05 | 목록 필드 존재. 원시 내용 보관 제외 |
| `/file/transfer/chunk/vs/{i}` | 4.05 | 4.05 | GET 불허, 전송 명령 안 함 |
| `/file/transfer/vs/{i}` | 2.05 | 2.05 | 전송 메타데이터. 원시 내용 보관 제외 |
| `/hass/command/vs/{i}` | 4.04 | 4.04 | 광고되었으나 GET 경로 없음 |
| `/hass/state/vs/{i}` | 2.05 | 2.05 | 내부 상태 코드, 의미 미확정 |
| `/humidity/{i}` | 2.05 값 0 | 2.05 빈맵 | 기본 습도 값 사용 보류 |
| `/humidity/vs/{i}` | 2.05 값 63 | 2.05 빈맵 | 전용 필드 우선 |
| `/information/vs/{i}` | 2.05 | 2.05 | 모델·버전·식별 필드 존재. 원시 식별 정보 보관 제외 |
| `/mode/{i}` | 2.05 | 2.05 빈맵 | 표준 모드 |
| `/mode/vs/{i}` | 2.05 | 2.05 빈맵 | 모드·추가 옵션 |
| `/multidevice/vs/{i}` | 2.05 값 1 | 광고 안 됨 | 하위 장치 수 원시 메타데이터 |
| `/power/{i}` | 2.05 Off | 2.05 빈맵 | 전원 |
| `/power/vs/{i}` | 2.05 Off | 2.05 빈맵 | vendor 전원 |
| `/rm/micomdata/vs/{i}` | 2.05, 데이터 길이 454 | 2.05 빈맵 | 제어기 원시 데이터 해석 미검증. 본문 보관 제외 |
| `/rm/state/vs/{i}` | 2.05 빈맵 | 2.05 빈맵 | 노출할 상태 없음 |
| `/sensors/vs/{i}` | 2.05 센서 5종 | 2.05 센서 5종, 모두 0 | 물리적 센서 존재·최신성 추가 검증 |
| `/temperature/current/{i}` | 2.05 25℃ | 2.05 빈맵 | 실내 온도 |
| `/temperature/desired/{i}` | 2.05 24℃ | 2.05 빈맵 | 설정 온도 |
| `/temperatures/vs/{i}` | 2.05 온도 값 | 2.05 설명 항목만 존재 | vendor 온도 배치 |

`/multidevice/vs/0`은 `numofsubdevice="1"`을 보냈습니다. `/device/1`과 일부 메타데이터·센서 경로는 응답하지만 해당 인덱스의 전원·모드·온도·습도·전력은 비어 있습니다. 이 사실만으로 두 번째 에어컨이 연결됐다고 판단하거나 Edge 자식 기기를 만들지 않습니다.

## 5. 구현 순서와 추가 검증

1. 기존 PC 도구의 기본 전원·온도 조회를 유지하고 `--all-state-reads`로 전체 개별 GET을 재현합니다. 성공·거부·빈 응답·필터링 결과를 별도로 저장합니다.
2. Lua 매핑에 습도·먼지 3종·냄새·순간 전력·누적 원시 카운터를 포함합니다. 숫자 문자열, 단위·범위, 미측정 값과 누락의 처리를 fixture로 검증합니다.
3. 허브의 읽기 prototype에서 전원·온도·습도를 우선 표시하고, 값과 단위·최신성을 확인한 센서·계량 기능을 profile에 추가합니다. 종합 등급·소모품 단계·알람 코드는 의미 확인 전까지 진단 자료로 유지합니다.
4. 사용자가 평소 사용하거나 별도로 승인한 운전 구간에서 앱 값 대조, 센서 변화, 누적 카운터 증분을 확인합니다. 이번 읽기 시험만으로 새 운전·측정 명령을 보내지 않습니다.
5. 무풍·자동 건조의 개별 설정 handler는 구현·모사 검사했습니다. 본인 장비의 쓰기·병합 검증은 남았습니다. 모니터링·취침 예약의 신규 제어와 원시 옵션 전체 쓰기는 제공하지 않습니다. [현재 설정 구현](control.md)

정상 주기에는 65개 경로를 반복 조회하지 않습니다. 탐색·초기 진단 때 전체 목록을 확인하고, 평소에는 `/device/0?if=oic.if.b` 배치를 장비별 단일 큐에서 읽습니다. 그 응답에서 실제 사용 항목을 추출하고 개별 GET은 진단·변경 확인에 사용하도록 제안합니다. 허브 부하·장시간 안정성은 아직 측정하지 않았습니다.
