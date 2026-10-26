#include "ILexer.h"
#include "Lexilla.h"
#import "ScintillaKit.h"

void *ScintillaCreateLexer(const char *name) { return CreateLexer(name); }

int ScintillaLexerCount(void) { return GetLexerCount(); }

const char *ScintillaLexerName(int index) {
    static char names[256][64];
    if (index < 0 || index >= 256) return "";
    GetLexerName(index, names[index], sizeof names[index]);
    return names[index];
}
