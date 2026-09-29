import { useCallback, useLayoutEffect, useRef, useState } from 'react'
import type { SpeechContext } from '@/lib/types'

type Mode = 'read' | 'ask' | null
type RecognitionResult = { readonly isFinal: boolean; readonly [index: number]: { transcript: string } }
type RecognitionEvent = {
  readonly resultIndex: number
  readonly results: { readonly length: number; readonly [index: number]: RecognitionResult }
}
type Recognition = {
  lang: string
  continuous: boolean
  interimResults: boolean
  onresult: ((event: RecognitionEvent) => void) | null
  onerror: ((event: { error: string }) => void) | null
  onend: (() => void) | null
  start: () => void
  stop: () => void
  abort: () => void
}
type RecognitionConstructor = new () => Recognition
type Session = {
  id: number
  context: SpeechContext
  stopping: boolean
  stream?: MediaStream
  recorder?: MediaRecorder
  recognition?: Recognition
  timer?: number
}
type Options = {
  context: SpeechContext | null
  onRead: (text: string, context: SpeechContext) => void | Promise<void>
  onAudio: (blob: Blob, context: SpeechContext) => void | Promise<void>
  onError: (message: string) => void
}

function release(session: Session) {
  if (session.timer !== undefined) window.clearInterval(session.timer)
  if (session.recorder) {
    session.recorder.ondataavailable = null
    session.recorder.onstop = null
    session.recorder.onerror = null
    try {
      if (session.recorder.state !== 'inactive') session.recorder.stop()
    } catch { /* 이미 종료된 장치도 아래에서 트랙을 정리한다. */ }
  }
  session.stream?.getTracks().forEach((track) => track.stop())
  if (session.recognition) {
    session.recognition.onresult = null
    session.recognition.onerror = null
    session.recognition.onend = null
    try { session.recognition.abort() } catch { /* 인식기가 이미 끝난 경우. */ }
  }
}

export function useSpeech({ context, onRead, onAudio, onError }: Options) {
  const [mode, setMode] = useState<Mode>(null)
  const [starting, setStarting] = useState(false)
  const [elapsed, setElapsed] = useState(0)
  const [interim, setInterim] = useState('')
  const active = useRef<Session | null>(null)
  const generation = useRef(0)
  const mounted = useRef(false)
  const browser = typeof window === 'undefined' ? undefined : window as Window & {
    SpeechRecognition?: RecognitionConstructor
    webkitSpeechRecognition?: RecognitionConstructor
  }
  const SpeechRecognition = browser?.SpeechRecognition ?? browser?.webkitSpeechRecognition

  const cancel = useCallback(() => {
    ++generation.current
    const session = active.current
    active.current = null
    if (session) release(session)
    if (mounted.current) {
      setMode(null)
      setStarting(false)
      setElapsed(0)
      setInterim('')
    }
  }, [])

  useLayoutEffect(() => {
    mounted.current = true
    return () => {
      mounted.current = false
      cancel()
    }
  }, [cancel])
  // 엔진 변경은 녹음을 유지하지만 문서·페이지 이동은 전송 없이 취소한다.
  useLayoutEffect(() => () => cancel(), [context?.docId, context?.page, cancel])

  function current(session: Session) {
    return mounted.current && active.current === session && generation.current === session.id
  }

  function deliver(callback: () => void | Promise<void>) {
    try {
      void Promise.resolve(callback()).catch((error: unknown) => {
        if (mounted.current) onError(error instanceof Error ? error.message : '음성 처리에 실패했습니다.')
      })
    } catch (error) {
      if (mounted.current) onError(error instanceof Error ? error.message : '음성 처리에 실패했습니다.')
    }
  }

  function begin(nextMode: Exclude<Mode, null>): Session | null {
    if (!context) {
      onError('교안을 먼저 선택하세요.')
      return null
    }
    if (nextMode === 'ask' && !context.stt?.model) {
      onError('모델 관리에서 질문 받아쓰기 모델을 선택하세요.')
      return null
    }
    const session: Session = {
      id: ++generation.current,
      context: { ...context, engine: context.engine ? { ...context.engine } : null, stt: context.stt ? { ...context.stt } : null },
      stopping: false,
    }
    active.current = session
    setMode(nextMode)
    setStarting(true)
    setElapsed(0)
    setInterim('')
    return session
  }

  function stop() {
    const session = active.current
    if (!session || session.stopping) return
    session.stopping = true
    try {
      if (session.recorder) {
        if (session.recorder.state !== 'inactive') session.recorder.stop()
      } else if (session.recognition) {
        session.recognition.stop()
      } else {
        cancel() // 마이크 권한을 기다리는 요청은 녹음 없이 취소한다.
      }
    } catch {
      cancel()
      onError('음성을 종료하지 못했습니다. 다시 시도하세요.')
    }
  }

  function toggleRead() {
    if (active.current) { stop(); return }
    if (!SpeechRecognition) {
      onError('이 브라우저는 영어 읽기 인식을 지원하지 않아요. Chrome을 사용하세요.')
      return
    }
    const session = begin('read')
    if (!session) return
    try {
      const recognition = new SpeechRecognition()
      session.recognition = recognition
      recognition.lang = 'en-US'
      recognition.continuous = true
      recognition.interimResults = true
      recognition.onresult = (event) => {
        if (!current(session)) return
        for (let index = event.resultIndex; index < event.results.length; index++) {
          const result = event.results[index]
          const text = result[0]?.transcript.trim() ?? ''
          setInterim(text)
          if (result.isFinal && text) deliver(() => onRead(text, session.context))
        }
      }
      recognition.onerror = (event) => {
        if (!current(session)) return
        if (event.error !== 'no-speech' && event.error !== 'aborted') {
          cancel()
          onError(`영어 음성 인식 오류: ${event.error}`)
        }
      }
      recognition.onend = () => { if (current(session)) cancel() }
      recognition.start()
      if (current(session)) setStarting(false)
    } catch {
      cancel()
      onError('영어 음성 인식을 시작하지 못했습니다. 마이크 권한을 확인하세요.')
    }
  }

  async function startAsk() {
    if (typeof MediaRecorder === 'undefined' || !navigator.mediaDevices?.getUserMedia) {
      onError('이 브라우저에서는 마이크 녹음을 사용할 수 없습니다.')
      return
    }
    const mime = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4'].find(
      (type) => typeof MediaRecorder.isTypeSupported === 'function' && MediaRecorder.isTypeSupported(type),
    )
    if (!mime) {
      onError('지원되는 녹음 형식이 없습니다. Chrome에서 다시 시도하세요.')
      return
    }
    const session = begin('ask')
    if (!session) return
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
      if (!current(session)) {
        stream.getTracks().forEach((track) => track.stop())
        return
      }
      session.stream = stream
      const recorder = new MediaRecorder(stream, { mimeType: mime })
      session.recorder = recorder
      const chunks: Blob[] = []
      recorder.ondataavailable = (event) => {
        if (current(session) && event.data.size) chunks.push(event.data)
      }
      recorder.onerror = () => {
        if (!current(session)) return
        cancel()
        onError('음성 녹음에 실패했습니다. 마이크를 확인하고 다시 시도하세요.')
      }
      recorder.onstop = () => {
        if (!current(session)) return
        const blob = new Blob(chunks, { type: recorder.mimeType || mime })
        cancel()
        if (blob.size) deliver(() => onAudio(blob, session.context))
        else onError('녹음된 음성이 없습니다. 다시 녹음하세요.')
      }
      recorder.start(250)
      if (!current(session)) return
      const startedAt = Date.now()
      setStarting(false)
      session.timer = window.setInterval(() => {
        if (current(session)) setElapsed(Math.floor((Date.now() - startedAt) / 1000))
      }, 500)
    } catch (error) {
      if (!current(session)) return
      cancel()
      onError(error instanceof Error ? `마이크를 쓸 수 없어요: ${error.message}` : '마이크를 쓸 수 없습니다.')
    }
  }

  function toggleAsk() {
    if (active.current) { stop(); return }
    void startAsk()
  }

  return { mode, starting, elapsed, interim, toggleRead, toggleAsk, stop, readSupported: !!SpeechRecognition }
}
