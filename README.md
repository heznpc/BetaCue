# BetaCue

Apple의 개발자용 상태 정보를 **지금 어떤 상태인지 · 왜 막혔는지 · 다음에 뭘 해야 하는지**로 바꿔 보여주고,
변화가 생기면 먼저 알려주는 개인용 iOS App Ops 대시보드. macOS 메뉴바 앱.

## 왜 만들었나

TestFlight는 상태를 세 곳에 나눠서 알려준다. 빌드 처리 상태(`processingState`),
내부 배포 상태(`internalBuildState`), 외부 배포 상태(`externalBuildState`).
Apple은 이 셋을 각각 줄 뿐, 그 조합이 무슨 뜻인지는 알려주지 않는다.

그래서 **처리가 끝난 정상 빌드가 아무에게도 전달되지 않는 상태**가 존재한다.
빌드는 `VALID`인데 연결된 테스터 그룹이 없으면 어떤 기기에도 나타나지 않는다.
어디에도 오류가 표시되지 않기 때문에 알아차리기 어렵고, 그대로 며칠이 지나기도 한다.

이 앱은 그 조합을 해석해서 지금 어떤 상태인지 · 왜 막혔는지 · 다음에 뭘 해야 하는지를
한 문장으로 바꾸고, 상태가 바뀌면 먼저 알린다.

## 설계 원칙

**조회 경로에 LLM을 쓰지 않는다.** 상태 판정은 전부 결정론적 코드다.
API 폴링, 상태 비교, blocker 검출, 다음 행동 결정, 알림 발생 여부 — 토큰 비용 0.

```
App Store Connect API
        ↓  Collector      호출을 병렬로 던져 정규화 스키마로 변환
        ↓  RuleEngine     결정론적 상태 판정
        ↓  StateStore     SQLite — 마지막 상태와 전이 로그
        ↓  SwiftUI        메뉴바 + 창
```

**"됐나"와 "지금 받을 수 있나"는 다른 질문이다.** 최신 빌드가 처리 중이어도 이전 빌드로
계속 테스트할 수 있다. 상태를 하나로 합치면 그 사실을 잃으므로 두 축으로 나눠 판정한다.

**그룹이 있다는 것과 이 빌드가 그 그룹에 연결됐다는 건 다른 사실이다.** 앱에 그룹이 있어도
빌드가 안 붙어 있으면 아무도 못 받는다. 개별 초대나 공개 링크로 배포됐을 수도 있다.
그래서 빌드별 연결 관계와 개별 테스터 수를 따로 수집한다.

**모르면 추측하지 않는다.** Apple이 예상 못 한 값을 주면 `UNKNOWN`으로 떨어뜨리고
원본을 그대로 보여준 뒤 App Store Connect로 넘긴다.

**Apple 용어를 화면에 노출하지 않는다.** `PROCESSING` 대신 "Apple 처리 중".
애기말도 쓰지 않는다 — 짧은 서술형 명사구로 쓴다.
원본이 필요하면 상세 화면의 "Apple 원본 정보"를 펼친다.

## 상태 모델

| 상태 | 화면 문구 | 다음 행동 |
|---|---|---|
| `NO_BUILD` | 업로드된 빌드 없음 | — |
| `BUILD_PROCESSING` | Apple 처리 중 | 없음 (대기) |
| `BUILD_INVALID` | 빌드 거부됨 | ASC에서 확인 |
| `BUILD_READY_NOT_DISTRIBUTED` | 배포 대상 없음 | 테스터에게 배포 |
| `INTERNAL_TESTING_READY` | 테스트 가능 | — |
| `EXTERNAL_REVIEW_REQUIRED` | 내부 테스트 가능 | ASC에서 확인 |
| `EXTERNAL_REVIEW_PENDING` | 외부 심사 중 | 없음 (대기) |
| `EXTERNAL_TESTING_READY` | 내부·외부 테스트 가능 | — |
| `ACTION_REQUIRED` | 조치 필요 | ASC에서 확인 |
| `UNKNOWN` | 상태 판별 불가 | ASC에서 확인 |

같은 상태 안에서도 원인을 구분한다(`MISSING_EXPORT_COMPLIANCE`, `EXPIRED`, `BETA_REJECTED`,
`NO_GROUPS`, `BUILD_NOT_ASSIGNED`, `GROUPS_EMPTY`). 전이 판정은 상태 ID가 아니라
`상태 + 원인 + 빌드 ID` 지문으로 하므로, 같은 칸 안에서 원인만 바뀌어도 알림이 나간다.

## 알림

모든 변경을 알리지 않는다. 알릴 가치가 있는 전이만 정의한다.

- 처리 중 → 테스트 준비 완료
- 처리 중 → 배포 안 됨 (조용히 실패하는 자리)
- 외부 심사 → 승인
- 빌드 거부
- 인증서 만료 임박 (60일 이내, 인증서당 한 번)

첫 조회에서는 알리지 않는다. 앱을 처음 켰을 때 알림이 쏟아지지 않게.

## 폴링

처리 중인 빌드가 있으면 1분, 경고 상태가 있으면 5분, 조용하면 15분.
창을 한 번도 열지 않아도 폴링과 알림은 계속된다.

## 설정

App Store Connect API 키가 필요하다. 키 파일(`.p8`)은 Apple이 정한 자리에 그대로 두고,
앱은 경로만 알고 있는다. 키를 복사하거나 다른 곳으로 옮기지 않는다.

```
~/.appstoreconnect/private_keys/AuthKey_<KeyID>.p8
~/.config/betacue/config.json     # Key ID와 Issuer ID만 저장
~/Library/Application Support/BetaCue/state.sqlite
```

## 빌드

`project.yml`의 `DEVELOPMENT_TEAM`을 자기 Apple 팀 ID로 채운다.
(Apple Developer 계정 → Membership에서 확인)

```bash
xcodegen generate
xcodebuild -project BetaCue.xcodeproj -scheme BetaCue -configuration Debug build
xcodebuild -project BetaCue.xcodeproj -scheme BetaCue test
```

App Sandbox는 꺼져 있다. 홈 디렉터리의 키 파일을 읽어야 하기 때문이다.
현재 지원하는 자격증명은 팀 API 키뿐이다. 개인(Individual) 키는 JWT에서 `iss` 대신 `sub`를
쓰므로 그대로는 동작하지 않는다.

## 실패 허용

앱 하나의 조회가 실패해도 나머지 앱은 갱신된다. 실패한 앱은 마지막으로 성공한 상태를 유지하고
어떤 항목을 못 읽었는지 상세 화면에 표시한다. 상태 모니터링 도구가 한 곳의 404로
전체를 멈추면 안 된다.

## v0 범위 밖

빌드를 그룹에 연결하는 것 외의 조작 — 테스터 CRUD, 업로드 파이프라인 자동화, 인증서 자동 발급, App Store 제출 전체 흐름,
AI 크래시 분석, 팀·계정·결제. 개인용 도구이므로 필요해지면 그때 넣는다.

`betaTesterUsages`가 현재 환경에서 404를 반환하고 테스터 `state`도 `null`로 오기 때문에
**"누가 설치했는지"는 표시하지 않는다.** 신뢰 가능한 데이터가 확보되기 전까지 노출하지 않는다.

## 라이선스

MIT. 자세한 내용은 [LICENSE](LICENSE).
