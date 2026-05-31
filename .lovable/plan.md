
# Live Q&A 상용화 1차 출시 계획

목표: 현재 단일 글로벌 Q&A를 **호스트 계정 + 이벤트(방) 단위** 멀티테넌트 SaaS로 전환하고, 발표자 모드와 AI 모더레이션을 얹은 뒤 **이벤트 1개당 $1 (월 1회 무료)** Stripe 결제를 붙입니다.

---

## 1. 사용자 흐름

```text
[호스트]                                  [청중]
회원가입/로그인 (Google/이메일)
  ↓
대시보드 → "새 이벤트 만들기"
  ↓
무료 슬롯 남음? ──예→ 무료 생성 → 활성
        │
        아니오 → Stripe Checkout $1 → 결제 성공 시 활성
  ↓
이벤트 활성: 6자리 코드 + QR + 공유 링크 생성
  ↓                                       ↓
발표자 모드 (대형 화면)         /e/{code} 진입
질문 표시/정렬/숨김/삭제         질문 작성·추천
                                 (이벤트별 익명/닉네임 옵션)
  ↓
이벤트 종료 → 통계 요약
```

---

## 2. MVP 기능 범위 (M1 + M2)

### M1 — 멀티테넌트 기반
- 호스트 인증: 이메일/비밀번호 + Google (Lovable 브로커)
- 호스트 대시보드: 내 이벤트 목록 / 생성 / 종료 / 삭제
- 이벤트(방) 모델: 6자리 영숫자 코드, 제목, 상태(draft/active/closed), 설정(익명·닉네임 선택)
- 참여 페이지 `/e/{code}`: 현재의 Q&A UI를 이벤트 범위로 재사용
- 호스트 관리 화면: 이벤트별 질문 삭제·숨김·고정, 전체 초기화
- 추천 1인 1회 제한은 현 방식(localStorage + 이벤트별 키) 유지

### M2 — 발표자 모드 + 모더레이션
- 발표자 모드 `/e/{code}/present`: 다크 테마, 큰 글씨, 자동 스크롤, 키보드 단축키(↑/↓/Enter로 다음/숨김/고정), OBS 브라우저 소스로도 사용 가능
- AI 모더레이션: Lovable AI (`google/gemini-2.5-flash`)로 부적절 콘텐츠 자동 플래그 → 호스트 큐에서 승인/거절
- 중복 질문 그룹핑(간단 임베딩 유사도 또는 정규화 텍스트 기준)

### 결제 (Stripe — Lovable 내장 seamless)
- **단위: 이벤트 1개 생성/활성화당 $1 (USD)**
- **무료 한도: 호스트당 매 캘린더 월 1개**
- 이벤트 생성 시점에 잔여 무료 슬롯 확인 → 없으면 Stripe Checkout으로 단건 결제 → 웹훅 수신 후 이벤트 `active` 전환
- 결제 이력 페이지 (간단한 영수증 목록)

### 범위 밖 (이번 출시 후순위)
- 워크스페이스/팀, 폴/퀴즈, 분석 리포트 PDF, 통합(Zoom/Slack), 화이트라벨, SSO

---

## 3. 데이터 모델 변경

새 테이블 (모두 `public` 스키마, RLS + GRANT 포함):

- `profiles` — `user_id (auth.users FK)`, `display_name`
- `events` — `id`, `owner_id`, `code(unique 6자)`, `title`, `status`, `allow_anonymous`, `created_at`, `closed_at`
- `questions` — 기존 테이블에 `event_id (FK)`, `is_hidden`, `is_pinned`, `is_flagged`, `moderation_status('pending'|'approved'|'rejected')`, `author_nickname?` 컬럼 추가 (기존 행은 마이그레이션에서 삭제 또는 기본 이벤트로 이관)
- `payments` — `id`, `user_id`, `event_id?`, `stripe_session_id`, `amount_cents`, `currency`, `status`, `created_at`
- `free_event_usage` — `user_id`, `year_month (YYYY-MM)`, `used_count` (월별 무료 카운터; UNIQUE(user_id, year_month))

RLS 핵심:
- `events`: 호스트는 본인 이벤트 전체 CRUD. 청중(anon)은 `status='active'` 인 이벤트의 메타데이터만 `code`로 SELECT.
- `questions`: SELECT는 해당 이벤트가 active이고 `is_hidden=false`이면 anon 허용. INSERT는 active 이벤트이면 anon 허용. UPDATE(추천)는 anon에게 `upvotes` 컬럼 증가만 허용. DELETE/숨김/고정은 호스트만.
- `payments`, `free_event_usage`: 본인만 SELECT, 서버(service_role)만 INSERT/UPDATE.

기존 글로벌 질문은 마이그레이션에서 비웁니다 (사용자 본인용 데이터라 보존 가치 낮음).

---

## 4. 결제 구현 (Stripe seamless)

1. `payments--recommend_payment_provider` → `payments--enable_stripe_payments` 실행
2. 세금 옵션: 디지털 서비스 + 글로벌이므로 **옵션 1 (managed_payments, 풀 컴플라이언스)** 권장. 호스트 확인 후 적용.
3. 상품 1개 생성: "Live Q&A Event Pass", $1.00 one-time
4. 서버 함수 `createEventCheckout` (TanStack `createServerFn`, `requireSupabaseAuth`):
   - 이번 달 `free_event_usage` 조회 → 0이면 무료로 즉시 이벤트 생성하고 카운터++, 종료
   - 그 외엔 Stripe Checkout Session 생성 (success_url에 `pending_event_id`)
5. 웹훅 `/api/public/webhooks/stripe`:
   - 서명 검증 → `checkout.session.completed` 수신 → `payments` 레코드 작성, 해당 `events.status='active'`로 전환
6. UI: 잔여 무료 1회 뱃지, 결제 진행 모달, 결제 성공/실패 토스트

---

## 5. 라우트 구조 (TanStack)

```text
src/routes/
  index.tsx                  랜딩 (제품 소개 + 로그인 CTA)
  login.tsx                  이메일/Google 로그인
  signup.tsx
  _authenticated.tsx         가드 레이아웃
  _authenticated/
    dashboard.tsx            내 이벤트 목록 + 새 이벤트
    events.$id.tsx           이벤트 관리 (모더레이션 큐 포함)
    events.$id.present.tsx   발표자 모드
    billing.tsx              결제 이력
  e.$code.tsx                청중 진입 (현 QnAPage 재사용·이벤트 스코프)
  api/public/webhooks/stripe.ts
```

서버 함수 (`src/lib/*.functions.ts`):
- `createEventCheckout`, `confirmEventPayment`, `listMyEvents`, `closeEvent`
- `moderateQuestion`, `hideQuestion`, `pinQuestion`, `deleteQuestion`
- `submitQuestion`, `upvoteQuestion` (anon 허용 → 서버 라우트 또는 RLS 직결)

---

## 6. 구현 순서 (수용 후 진행)

1. DB 마이그레이션 (profiles/events/questions 확장/payments/free_event_usage + RLS + GRANT)
2. 인증 (이메일 + Google 브로커, `configure_social_auth`, `attachSupabaseAuth` 확인)
3. 대시보드 + 이벤트 CRUD + `/e/{code}` 이벤트 스코프 변환
4. 발표자 모드 + 호스트 모더레이션 UI
5. AI 모더레이션 (Lovable AI 호출, pending 큐)
6. Stripe enable → 상품 생성 → checkout/webhook → 무료 카운터
7. 랜딩 페이지 + 가격 안내 ($1/event, 월 1회 무료)
8. 결제·인증 전 흐름 수동 QA → 게시

---

## 7. 주의/리스크

- **이벤트 코드 충돌**: 6자리 영숫자(약 22억 조합)로 충분. UNIQUE 제약 + 충돌 시 재생성 루프.
- **익명 청중의 어뷰징**: localStorage 우회는 막기 어렵습니다. 1차에선 그대로 두고, 후속에서 IP 기반 레이트리밋 추가.
- **월 무료 1회 정산 시점**: 캘린더 월(UTC) 기준으로 단순화. 호스트 타임존 이슈는 후순위.
- **환불 정책 명시 필요**: $1 단건이라 기본 무환불 안내문을 결제 화면에 표시.
- **현재 글로벌 질문 데이터**: 이번 마이그레이션에서 삭제 예정. 보존이 필요하면 알려주세요.

승인하시면 1번(DB 마이그레이션)부터 시작하겠습니다.
