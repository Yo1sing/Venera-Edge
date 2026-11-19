import 'package:prism_ui/icons/glyph.dart';

// The four mobile dock glyphs from FlClash's AppGlyphs (GPL-3.0).
abstract final class MainNavigationGlyphs {
  static const dashboard = Glyph([
    GlyphBox(3.5, 3.5, 10.5, 11.5, 2),
    GlyphBox(13.5, 3.5, 20.5, 9.5, 2),
    GlyphBox(3.5, 14.5, 10.5, 20.5, 2),
    GlyphBox(13.5, 12.5, 20.5, 20.5, 2),
  ]);

  static const proxies = Glyph([
    GlyphCircle(12, 12, 8.8),
    GlyphOval(8.2, 3.2, 15.8, 20.8, role: GlyphRole.detail),
    GlyphPolyline([
      GlyphVertex(3.2, 12),
      GlyphVertex(20.8, 12),
    ], role: GlyphRole.detail),
  ]);

  static const profiles = Glyph([
    GlyphPolyline([
      GlyphVertex(5, 3, 2.5),
      GlyphVertex(13.5, 3, 1),
      GlyphVertex(19, 8.5, 1),
      GlyphVertex(19, 21, 2.5),
      GlyphVertex(5, 21, 2.5),
    ], closed: true),
    GlyphPolyline([
      GlyphVertex(13.5, 3.2),
      GlyphVertex(13.5, 8.5, 1.5),
      GlyphVertex(18.8, 8.5),
    ], role: GlyphRole.detail),
    GlyphPolyline([
      GlyphVertex(8.5, 12.5),
      GlyphVertex(15.5, 12.5),
    ], role: GlyphRole.detail),
    GlyphPolyline([
      GlyphVertex(8.5, 16),
      GlyphVertex(13, 16),
    ], role: GlyphRole.detail),
  ]);

  static const tools = Glyph([
    GlyphBox(3, 7, 21, 20, 2.8),
    GlyphPolyline([
      GlyphVertex(9, 7),
      GlyphVertex(9, 4.6, 1.4),
      GlyphVertex(15, 4.6, 1.4),
      GlyphVertex(15, 7),
    ], role: GlyphRole.line),
    GlyphPolyline([
      GlyphVertex(3.2, 12.6),
      GlyphVertex(9.6, 12.6),
    ], role: GlyphRole.detail),
    GlyphPolyline([
      GlyphVertex(14.4, 12.6),
      GlyphVertex(20.8, 12.6),
    ], role: GlyphRole.detail),
    GlyphBox(10.4, 11, 13.6, 14.4, 1, role: GlyphRole.detail),
  ]);
}
