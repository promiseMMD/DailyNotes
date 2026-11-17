import 'dart:convert';

import '../dailynotes/editor/document_envelope.dart';
import 'mod_lan_rich.dart';

bool isNativeModMonthDocument(String raw) =>
    DailyNotesDocumentEnvelope.hasNativeDocument(raw);

/// The local store accepts either its existing strict Tiptap subset or a
/// complete native AppFlowy envelope. LAN writes keep their narrower contract.
void validateModMonthDocument(String raw) {
  if (DailyNotesDocumentEnvelope.hasNativeDocument(raw)) {
    DailyNotesDocumentEnvelope.decode(raw);
  } else {
    ModLanRichDocument.validate(jsonDecode(raw));
  }
}
