# 영한번역 프런트엔드

shadcn 공식 CLI의 Vite + React + TypeScript + Base UI / Nova 템플릿에서 시작했다. 설치·실행·구성 명령은 [프로젝트 README](../README.md)를 참고한다.

```bash
pnpm install --frozen-lockfile
pnpm dev
pnpm lint
pnpm build
```

개발 서버는 `127.0.0.1:5173`이며 `/api`를 FastAPI `127.0.0.1:8766`으로 전달한다. 일반 실행은 저장소 루트의 `./run.sh`로 빌드·서빙한다.

파일 목록의 사각형 선택·교차 판정·자동 스크롤은 [Viselect](https://simonwep.github.io/viselect/pages/custom-integration.html)를 사용한다. 선택한 교안 ID, Shift 범위 기준점과 한 번 클릭 열기는 `useLibrarySelection`에서 앱 동작에 연결한다.
