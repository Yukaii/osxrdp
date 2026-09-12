# osxrdp - macOS 용 xrdp
## 개요
osxrdp 는 macOS에서 rdp 서버를 사용할 수 있게 해주는 xrdp의 비공식 모듈입니다.
<img width="1282" height="832" alt="OSXRDP" src="https://github.com/user-attachments/assets/0980b2b5-f50c-4fa6-88ba-c4c8eaa29ec5" />


<h6><a href="https://www.youtube.com/watch?v=ltxx2bha5-8">영상</a></h6>

## 기능
|기능|상태|
|------|---|
|부드러운 화면 제어 (H.264)|✅|
|가상 모니터 (클라이언트에 맞는 해상도 지원)|✅|
|로그온되지 않은 macOS 사용자를 사용한 제어|✅|
|기본 클립보드 (텍스트)|✅|
|고급 클립보드 (이미지, 서식 있는 텍스트)|✅|
|다중 모니터 (H.264 전용)|✅|
|파일 전송|✅|
|오디오|❌|

## 사용법
<h6><a href="Manual_ko.md">링크</h6>

## 지원 OS
macOS 12.4 이상\
Apple Silicon 및 Intel 맥을 지원합니다.

## 기타
osxrdp 는 xrdp v0.10.6.1 버전을 사용합니다. \
(macOS 에서 좋은 H.264 품질을 위해 약간의 인코더 옵션 조정이 있었습니다. 수정사항은 scripts/xrdp_patch.patch 에 있습니다.)
