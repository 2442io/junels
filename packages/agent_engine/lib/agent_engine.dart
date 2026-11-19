/// Offline-Agenten-Kern: llama.cpp-Engine, Geräteprofil, GGUF-Prüfung,
/// Agenten-Schleife mit GBNF und lokale Tools. Keine Netzwerkzugriffe.
library;

export 'src/agent/agent_runner.dart';
export 'src/agent/builtin_tools.dart';
export 'src/agent/document_tools.dart';
export 'src/agent/grammar.dart';
export 'src/agent/memory_tools.dart';
export 'src/agent/network_tools.dart';
export 'src/agent/tool.dart';
export 'src/catalog.dart';
export 'src/device_profile.dart';
export 'src/documents/md_blocks.dart';
export 'src/documents/pdf_writer.dart' show buildPdfDocument, buildSlidesPdf, ImageResolver;
export 'src/documents/pptx_writer.dart';
export 'src/documents/raster.dart';
export 'src/downloader.dart';
export 'src/gguf_header.dart';
export 'src/image_gen.dart';
export 'src/knowledge.dart';
export 'src/llama_engine.dart';
export 'src/speech_text.dart';
export 'src/stt_engine.dart';
export 'src/vad.dart';
