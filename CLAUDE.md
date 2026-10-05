# supabase-defold - Claude Agent Guide

Defold 용 순수 Lua Supabase 클라이언트 라이브러리. 사용자 문서는 `README.md` (영문).

## 구조
- `supabase/`: 라이브러리 본체 (`game.project` 의 `[library] include_dirs = supabase` 로 공유). `require("supabase.client")`
  - 서비스별 모듈: `auth`, `db`, `rpc`, `storage`, `functions`, `realtime` / 공용: `util`(순수 Lua), `platform`(Defold 어댑터)
- `tests/`: LuaJIT 유닛 테스트. `tests/helpers.lua` 의 가짜 HTTP/타이머/WebSocket 사용 (Defold API 미사용)
- `example/`: 실서버 스모크 테스트 (부트스트랩 컬렉션)
  - `example/supabase/`: 스모크 테스트용 Supabase CLI 프로젝트 (config.toml, migrations, functions). 루트 `supabase/` 는 라이브러리라 CLI 는 항상 `--workdir example` 로 실행
  - `tools/setup_supabase.sh link|remote|local|reset|stop`. remote/local 은 `game.project` `[supabase]` 에 URL/키를 채운다 (커밋 금지)
- 스키마 변경은 새 마이그레이션 파일로만 추가한다 (적용된 파일 수정 금지)

## 규칙
- `supabase/ext.properties`: game.project 에디터 폼의 Supabase 섹션. 옵션을 추가하면 `platform.config()` 와 README 도 함께 갱신한다.
- Defold 전역(`http`, `json`, `timer`, `sys`, `websocket`)은 `supabase/platform.lua` 에서만 사용한다. 나머지는 순수 Lua 로 유지해 LuaJIT 단독 테스트가 가능해야 한다.
- Defold `json.encode` 는 빈 테이블을 `{}` 로 인코딩하므로, 서버가 배열을 기대하는 빈 필드는 생략한다.
- 빌드 검증: 에디터 없이 `java -cp <Defold jar> com.dynamo.bob.Bob --platform arm64-macos --build-server https://build.defold.com resolve build`
- 기능 추가 시 해당 모듈의 `tests/test_*.lua` 에 테스트를 추가하고, `README.md` 의 API 표와 Feature coverage 표를 갱신한다.
- 검증: `tools/verify.sh` (에디터 미실행 시 `--no-compile`).
