// Minimaler ZIP-Schreiber (Deflate), z. B. für PPTX/DOCX.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'raster.dart' show crc32;

class ZipWriter {
  final _entries = <({String name, Uint8List data})>[];

  void addString(String name, String content) => add(name, Uint8List.fromList(utf8.encode(content)));

  void add(String name, Uint8List data) => _entries.add((name: name, data: data));

  Uint8List build() {
    final out = BytesBuilder(copy: false);
    final central = BytesBuilder(copy: false);
    void u16(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
    void u32(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
    // feste Zeit: 1.1.2026 00:00 (DOS-Format)
    const dosTime = 0, dosDate = ((2026 - 1980) << 9) | (1 << 5) | 1;

    for (final e in _entries) {
      final name = utf8.encode(e.name);
      final crc = crc32(e.data);
      // Bilder sind schon komprimiert → speichern; Rest deflaten
      final store = e.name.endsWith('.png') || e.name.endsWith('.jpg') || e.name.endsWith('.jpeg');
      final comp = store ? e.data : Uint8List.fromList(ZLibEncoder(raw: true, level: 6).convert(e.data));
      final method = store ? 0 : 8;
      final offset = out.length;
      u32(out, 0x04034b50);
      u16(out, 20);
      u16(out, 0x0800); // UTF-8-Namen
      u16(out, method);
      u16(out, dosTime);
      u16(out, dosDate);
      u32(out, crc);
      u32(out, comp.length);
      u32(out, e.data.length);
      u16(out, name.length);
      u16(out, 0);
      out.add(name);
      out.add(comp);

      u32(central, 0x02014b50);
      u16(central, 20);
      u16(central, 20);
      u16(central, 0x0800);
      u16(central, method);
      u16(central, dosTime);
      u16(central, dosDate);
      u32(central, crc);
      u32(central, comp.length);
      u32(central, e.data.length);
      u16(central, name.length);
      u16(central, 0);
      u16(central, 0);
      u16(central, 0);
      u16(central, 0);
      u32(central, 0);
      u32(central, offset);
      central.add(name);
    }
    final cdOffset = out.length;
    final cd = central.takeBytes();
    out.add(cd);
    u32(out, 0x06054b50);
    u16(out, 0);
    u16(out, 0);
    u16(out, _entries.length);
    u16(out, _entries.length);
    u32(out, cd.length);
    u32(out, cdOffset);
    u16(out, 0);
    return out.takeBytes();
  }
}
