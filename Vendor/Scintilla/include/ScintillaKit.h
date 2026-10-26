// Swift-visible part of Scintilla (the Notepad++ editing component) and Lexilla (its syntax highlighters).
#import <Cocoa/Cocoa.h>
#import "Scintilla.h"
#import "SciLexer.h"
#import "ScintillaView.h"

NS_ASSUME_NONNULL_BEGIN
#ifdef __cplusplus
extern "C" {
#endif

/// Creates a Lexilla lexer by name ("cpp", "python", "hypertext", ...) for SCI_SETILEXER; NULL if the name is unknown.
void *_Nullable ScintillaCreateLexer(const char *name);
/// Number of lexers Lexilla knows and the name of each.
int ScintillaLexerCount(void);
const char *ScintillaLexerName(int index);

#ifdef __cplusplus
}
#endif
NS_ASSUME_NONNULL_END
