import Foundation

/// What a lexer style means, so a theme can colour every Lexilla lexer the same way.
enum TokenKind: String, CaseIterable {
    case comment, commentDoc, number, keyword, type, function, string, regex, preprocessor, `operator`
    case tag, attribute, entity, variable, label, heading, emphasis, link, error, added, deleted, changed
}

/// A language in the Language menu: the Lexilla lexer, keyword lists, comment syntax and file name patterns.
struct Language: Equatable {
    let name: String
    let lexer: String
    var extensions: [String] = []
    var fileNames: [String] = []
    var shebang: [String] = []
    /// Lexilla keyword sets (0 = primary keywords, 1 = types/secondary...).
    var keywords: [String] = []
    var lineComment: String?
    var blockComment: (String, String)?
    /// Regex for the Function List; group 1 is the name.
    var functionPattern: String?
    /// Lexer properties beyond folding.
    var properties: [String: String] = [:]

    static func == (a: Language, b: Language) -> Bool { a.name == b.name }

    static let normal = Language(name: "Normal text", lexer: "null", extensions: ["txt", "text", "log"])

    static func detect(url: URL?, firstLine: String) -> Language {
        if let url {
            let name = url.lastPathComponent.lowercased()
            if let lang = all.first(where: { $0.fileNames.contains(name) }) { return lang }
            let ext = url.pathExtension.lowercased()
            if !ext.isEmpty, let lang = all.first(where: { $0.extensions.contains(ext) }) { return lang }
        }
        if firstLine.hasPrefix("#!") {
            if let lang = all.first(where: { lang in lang.shebang.contains { firstLine.contains($0) } }) { return lang }
        }
        if firstLine.hasPrefix("<?xml") { return named("XML") ?? .normal }
        if firstLine.lowercased().hasPrefix("<!doctype html") { return named("HTML") ?? .normal }
        return .normal
    }

    static func named(_ name: String) -> Language? { all.first { $0.name == name } }

    // MARK: Keyword lists

    private static let cKeywords = "auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while _Bool _Complex bool true false NULL"
    private static let cppKeywords = cKeywords + " alignas alignof and asm catch class constexpr const_cast consteval constinit co_await co_return co_yield concept decltype delete dynamic_cast explicit export friend mutable namespace new noexcept not nullptr operator or private protected public reinterpret_cast requires static_assert static_cast template this thread_local throw try typeid typename using virtual wchar_t char8_t char16_t char32_t override final"
    private static let cppTypes = "size_t ssize_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t intptr_t uintptr_t std string vector map set unordered_map shared_ptr unique_ptr"
    private static let javaKeywords = "abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while var record sealed permits yield true false null"
    private static let csKeywords = "abstract as base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern false finally fixed float for foreach goto if implicit in int interface internal is lock long namespace new null object operator out override params private protected public readonly ref return sbyte sealed short sizeof stackalloc static string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using virtual void volatile while async await var dynamic get set value where yield record init required"
    private static let jsKeywords = "async await break case catch class const continue debugger default delete do else export extends false finally for from function get if import in instanceof let new null of return set static super switch this throw true try typeof undefined var void while with yield"
    private static let tsKeywords = jsKeywords + " abstract any as asserts bigint boolean declare enum implements infer interface is keyof module namespace never number object private protected public readonly require satisfies string symbol type unique unknown override"
    private static let swiftKeywords = "associatedtype actor async await break case catch class continue default defer deinit do else enum extension fallthrough false fileprivate final for func guard if import in indirect infix init inout internal is lazy let mutating nil nonisolated open operator optional override postfix precedencegroup prefix private protocol public repeat required rethrows return self Self some any static struct subscript super switch throw throws true try typealias unowned var weak where while willSet didSet get set consuming borrowing sending package macro"
    private static let swiftTypes = "Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Double Float Bool String Character Array Dictionary Set Optional Result Error Void Any AnyObject Data URL Date"
    private static let goKeywords = "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var true false nil iota"
    private static let goTypes = "bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any append cap close copy delete len make new panic print println recover"
    private static let kotlinKeywords = "as break class continue do else false for fun if in interface is null object package return super this throw true try typealias typeof val var when while by catch constructor delegate dynamic field file finally get import init param property receiver set setparam where actual abstract annotation companion const crossinline data enum expect external final infix inline inner internal lateinit noinline open operator out override private protected public reified sealed suspend tailrec vararg"
    private static let rustKeywords = "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type union unsafe use where while macro_rules"
    private static let rustTypes = "bool char f32 f64 i8 i16 i32 i64 i128 isize str u8 u16 u32 u64 u128 usize String Vec Option Result Box Rc Arc Some None Ok Err"
    private static let pythonKeywords = "False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case"
    private static let pythonBuiltins = "abs all any bool bytes callable chr dict dir divmod enumerate eval exec filter float format frozenset getattr globals hasattr hash help hex id input int isinstance issubclass iter len list locals map max min next object oct open ord pow print property range repr reversed round set setattr slice sorted staticmethod str sum super tuple type vars zip self cls"
    private static let phpKeywords = "abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield true false null"
    private static let rubyKeywords = "BEGIN END alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require require_relative attr_accessor attr_reader attr_writer include extend puts"
    private static let perlKeywords = "my our local sub package use no require if elsif else unless while until for foreach do last next redo return print printf open close die warn eval defined undef shift push pop unshift splice keys values each exists delete scalar wantarray ref bless chomp chop split join map grep sort reverse"
    private static let luaKeywords = "and break do else elseif end false for function goto if in local nil not or repeat return then true until while"
    private static let luaBuiltins = "assert collectgarbage dofile error getmetatable ipairs load loadfile next pairs pcall print rawequal rawget rawlen rawset require select setmetatable tonumber tostring type xpcall string table math io os coroutine utf8 debug package"
    private static let bashKeywords = "if then else elif fi case esac for select while until do done in function time return exit break continue local export readonly declare typeset unset shift source alias echo printf read cd pwd test eval exec set trap wait true false"
    private static let batchKeywords = "rem set if exist errorlevel for in do break call copy chcp cd chdir choice cls country ctty date del erase dir echo exit goto loadfix loadhigh mkdir md move path pause prompt rename ren rmdir rd shift time type ver verify vol com con lpt nul defined not else endlocal setlocal start title color"
    private static let powershellKeywords = "begin break catch class continue data define do dynamicparam else elseif end enum exit filter finally for foreach from function hidden if in param process return static switch throw trap try until using var while workflow"
    private static let sqlKeywords = "absolute action add all alter and any as asc authorization avg begin between by cascade case cast check close column commit constraint count create cross current cursor database declare default delete desc distinct drop else end escape except exec execute exists fetch foreign from full function grant group having if in index inner insert intersect into is join key left like limit max min not null of offset on open or order outer primary procedure references revoke right rollback select set some sum table then to top transaction trigger truncate union unique update use values view when where while with"
    private static let sqlTypes = "bigint binary bit blob boolean char date datetime decimal double float int integer money nchar numeric nvarchar real smallint text time timestamp tinyint uniqueidentifier varbinary varchar xml json"
    private static let htmlTags = "a abbr address area article aside audio b base bdi bdo blockquote body br button canvas caption cite code col colgroup data datalist dd del details dfn dialog div dl dt em embed fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 head header hr html i iframe img input ins kbd label legend li link main map mark meta meter nav noscript object ol optgroup option output p param picture pre progress q rp rt ruby s samp script section select small source span strong style sub summary sup svg table tbody td template textarea tfoot th thead time title tr track u ul var video wbr alt async autocomplete autofocus autoplay charset checked class cols colspan content controls crossorigin defer dir disabled download draggable for form height hidden href hreflang id lang list loop max maxlength media method min multiple muted name novalidate onblur onchange onclick onerror onfocus oninput onkeydown onkeyup onload onmouseover onsubmit open pattern placeholder readonly rel required reversed rows rowspan sandbox scope selected size sizes span spellcheck src srcset start step style tabindex target title type value width wrap"
    private static let cssKeywords = "align-content align-items align-self animation background background-color background-image background-position background-repeat background-size border border-bottom border-collapse border-color border-left border-radius border-right border-style border-top border-width bottom box-shadow box-sizing clear clip color column-gap columns content cursor display filter flex flex-basis flex-direction flex-grow flex-shrink flex-wrap float font font-family font-size font-style font-weight gap grid grid-area grid-column grid-row grid-template-areas grid-template-columns grid-template-rows height justify-content justify-items left letter-spacing line-height list-style margin margin-bottom margin-left margin-right margin-top max-height max-width min-height min-width object-fit opacity order outline overflow overflow-x overflow-y padding padding-bottom padding-left padding-right padding-top pointer-events position right row-gap text-align text-decoration text-overflow text-shadow text-transform top transform transition user-select vertical-align visibility white-space width word-break word-wrap z-index"
    private static let cmakeKeywords = "add_custom_command add_custom_target add_definitions add_dependencies add_executable add_library add_subdirectory add_test cmake_minimum_required configure_file else elseif endforeach endfunction endif endmacro endwhile file find_library find_package find_path foreach function get_filename_component if include include_directories install link_directories list macro message option project return set set_property set_target_properties string target_compile_definitions target_compile_options target_include_directories target_link_libraries while"
    private static let vbKeywords = "addressof and as boolean byref byte byval call case catch class const continue date decimal declare default dim do double each else elseif end enum erase error event exit false finally for friend function get goto handles if implements imports in inherits integer interface is let lib like long loop me mod module new next not nothing object of on option optional or overloads overridable overrides paramarray private property protected public raiseevent readonly redim rem resume return select set shadows shared short single static step stop string structure sub then throw to true try typeof until variant wend when while with withevents writeonly xor"
    private static let pascalKeywords = "and array as asm begin case class const constructor destructor div do downto else end except exports file finalization finally for function goto if implementation in inherited initialization inline interface is label library mod nil not object of or out packed procedure program property raise record repeat resourcestring set shl shr string then threadvar to try type unit until uses var while with xor"
    private static let rKeywords = "if else repeat while function for in next break TRUE FALSE NULL Inf NaN NA NA_integer_ NA_real_ NA_character_ library require return"
    private static let matlabKeywords = "break case catch classdef continue else elseif end for function global if otherwise parfor persistent return spmd switch try while"
    private static let fortranKeywords = "allocatable allocate assign backspace block call case character close common complex contains continue cycle data deallocate default dimension do double else elseif end enddo endif entry equivalence exit external format function go goto if implicit in inout include integer intent interface intrinsic logical module namelist none nullify only open operator optional out parameter pause pointer precision print private procedure program public read real recursive result return rewind save select sequence stop subroutine target then to type use where while write"
    private static let haskellKeywords = "case class data default deriving do else foreign if import in infix infixl infixr instance let module newtype of then type where forall mdo family role pattern static stock anyclass via"
    private static let erlangKeywords = "after and andalso band begin bnot bor bsl bsr bxor case catch cond div end fun if let not of or orelse receive rem try when xor"
    private static let tclKeywords = "after append array break case catch cd close concat continue else elseif eof error eval exec exit expr fconfigure file flush for foreach format gets glob global if incr info join lappend lindex linsert list llength lrange lreplace lsearch lsort namespace open package proc puts pwd read regexp regsub rename return scan seek set source split string subst switch tell time trace unset update uplevel upvar variable vwait while"
    private static let dartKeywords = "abstract as assert async await break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory false final finally for Function get hide if implements import in interface is late library mixin new null on operator part required rethrow return set show static super switch sync this throw true try typedef var void while with yield"
    private static let juliaKeywords = "abstract baremodule begin break catch const continue do else elseif end export false finally for function global if import let local macro module mutable primitive quote return struct true try type using while where"
    private static let zigKeywords = "addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const continue defer else enum errdefer error export extern fn for if inline linksection noalias noinline nosuspend opaque or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace var volatile while true false null undefined"
    private static let nimKeywords = "addr and as asm bind block break case cast concept const continue converter defer discard distinct div do elif else end enum except export finally for from func if import in include interface is isnot iterator let macro method mixin mod nil not notin object of or out proc ptr raise ref return shl shr static template try tuple type using var when while xor yield"
    private static let groovyKeywords = javaKeywords + " def as in trait it"
    private static let scalaKeywords = "abstract case catch class def do else extends false final finally for forSome if implicit import lazy match new null object override package private protected return sealed super this throw trait try true type val var while with yield given using enum then export"

    private static let cFunction = #"^[ \t]*(?:[\w:<>\*&,\[\]]+[ \t\*&]+)+([A-Za-z_~][\w:~]*)[ \t]*\([^;{]*\)[ \t\w]*(?:\{|$)"#
    private static let cLike = ("/*", "*/")

    // MARK: All languages

    static let all: [Language] = [
        .normal,
        Language(name: "Ada", lexer: "ada", extensions: ["ada", "ads", "adb"], lineComment: "--"),
        Language(name: "Assembly", lexer: "asm", extensions: ["asm", "s"], lineComment: ";"),
        Language(name: "AutoIt", lexer: "au3", extensions: ["au3"], lineComment: ";"),
        Language(name: "Batch", lexer: "batch", extensions: ["bat", "cmd", "nt"], keywords: [batchKeywords], lineComment: "REM "),
        Language(name: "C", lexer: "cpp", extensions: ["c", "h"], keywords: [cKeywords], lineComment: "//", blockComment: cLike, functionPattern: cFunction),
        Language(name: "C#", lexer: "cpp", extensions: ["cs", "csx"], keywords: [csKeywords], lineComment: "//", blockComment: cLike,
                 functionPattern: #"^[ \t]*(?:(?:public|private|protected|internal|static|virtual|override|async|abstract|sealed|partial|extern|unsafe|new)[ \t]+)*[\w<>\[\],\?]+[ \t]+(\w+)[ \t]*(?:<[^>]*>)?\("#),
        Language(name: "C++", lexer: "cpp", extensions: ["cpp", "cxx", "cc", "hpp", "hxx", "hh", "ino", "inl", "tpp", "ipp"], keywords: [cppKeywords, cppTypes],
                 lineComment: "//", blockComment: cLike, functionPattern: cFunction),
        Language(name: "CMake", lexer: "cmake", extensions: ["cmake"], fileNames: ["cmakelists.txt"], keywords: [cmakeKeywords], lineComment: "#"),
        Language(name: "CoffeeScript", lexer: "coffeescript", extensions: ["coffee"], lineComment: "#"),
        Language(name: "CSS", lexer: "css", extensions: ["css", "scss", "less"], keywords: [cssKeywords], blockComment: cLike,
                 functionPattern: #"^[ \t]*([^\s{][^{]*?)[ \t]*\{"#),
        Language(name: "D", lexer: "d", extensions: ["d"], lineComment: "//", blockComment: cLike),
        Language(name: "Dart", lexer: "dart", extensions: ["dart"], keywords: [dartKeywords], lineComment: "//", blockComment: cLike, functionPattern: cFunction),
        Language(name: "Diff", lexer: "diff", extensions: ["diff", "patch"]),
        Language(name: "Erlang", lexer: "erlang", extensions: ["erl", "hrl"], keywords: [erlangKeywords], lineComment: "%"),
        Language(name: "Fortran", lexer: "fortran", extensions: ["f90", "f95", "f03", "f08", "for"], keywords: [fortranKeywords], lineComment: "!"),
        Language(name: "Fortran 77", lexer: "f77", extensions: ["f", "f77"], keywords: [fortranKeywords], lineComment: "C "),
        Language(name: "F#", lexer: "fsharp", extensions: ["fs", "fsi", "fsx"], lineComment: "//", blockComment: ("(*", "*)")),
        Language(name: "GDScript", lexer: "gdscript", extensions: ["gd"], lineComment: "#"),
        Language(name: "Go", lexer: "cpp", extensions: ["go"], keywords: [goKeywords, goTypes], lineComment: "//", blockComment: cLike,
                 functionPattern: #"^func[ \t]+(?:\([^)]*\)[ \t]*)?(\w+)"#),
        Language(name: "Groovy", lexer: "cpp", extensions: ["groovy", "gradle"], keywords: [groovyKeywords], lineComment: "//", blockComment: cLike),
        Language(name: "Haskell", lexer: "haskell", extensions: ["hs", "lhs"], keywords: [haskellKeywords], lineComment: "--", blockComment: ("{-", "-}")),
        Language(name: "HTML", lexer: "hypertext", extensions: ["html", "htm", "shtml", "xhtml", "vue", "svelte", "jsp", "asp", "aspx"],
                 keywords: [htmlTags, jsKeywords], blockComment: ("<!--", "-->"), properties: ["fold.html": "1"]),
        Language(name: "INI file", lexer: "props", extensions: ["ini", "inf", "cfg", "conf", "properties", "editorconfig", "desktop"],
                 fileNames: [".gitconfig", ".editorconfig"], lineComment: ";", functionPattern: #"^\[([^\]]+)\]"#),
        Language(name: "Java", lexer: "cpp", extensions: ["java"], keywords: [javaKeywords], lineComment: "//", blockComment: cLike, functionPattern: cFunction),
        Language(name: "JavaScript", lexer: "cpp", extensions: ["js", "mjs", "cjs", "jsx"], shebang: ["node"], keywords: [jsKeywords], lineComment: "//", blockComment: cLike,
                 functionPattern: #"(?:^|[ \t])(?:function[ \t]*\*?[ \t]+(\w+)|(\w+)[ \t]*[:=][ \t]*(?:async[ \t]+)?(?:function\b|\([^)]*\)[ \t]*=>))"#,
                 properties: ["lexer.cpp.backquoted.strings": "1"]),
        Language(name: "JSON", lexer: "json", extensions: ["json", "jsonc", "json5", "geojson", "webmanifest"], lineComment: "//", blockComment: cLike,
                 properties: ["lexer.json.allow.comments": "1", "lexer.json.escape.sequence": "1"]),
        Language(name: "Julia", lexer: "julia", extensions: ["jl"], keywords: [juliaKeywords], lineComment: "#"),
        Language(name: "Kotlin", lexer: "cpp", extensions: ["kt", "kts"], keywords: [kotlinKeywords], lineComment: "//", blockComment: cLike,
                 functionPattern: #"\bfun[ \t]+(?:<[^>]*>[ \t]*)?(?:[\w.]+\.)?(\w+)"#),
        Language(name: "LaTeX", lexer: "latex", extensions: ["tex", "sty", "cls", "ltx"], lineComment: "%", functionPattern: #"\\(?:sub)*section\*?\{([^}]*)\}"#),
        Language(name: "Lisp", lexer: "lisp", extensions: ["lisp", "lsp", "el", "cl", "scm", "clj"], lineComment: ";"),
        Language(name: "Lua", lexer: "lua", extensions: ["lua"], shebang: ["lua"], keywords: [luaKeywords, luaBuiltins], lineComment: "--", blockComment: ("--[[", "]]"),
                 functionPattern: #"function[ \t]+([\w.:]+)"#),
        Language(name: "Makefile", lexer: "makefile", extensions: ["mak", "mk"], fileNames: ["makefile", "gnumakefile"], lineComment: "#",
                 functionPattern: #"^([\w.\-/$()%]+)[ \t]*:(?!=)"#),
        Language(name: "Markdown", lexer: "markdown", extensions: ["md", "markdown", "mdown", "mkd"], functionPattern: #"^#{1,6}[ \t]+(.+)$"#),
        Language(name: "MATLAB", lexer: "matlab", extensions: ["matlab"], keywords: [matlabKeywords], lineComment: "%", functionPattern: #"^\s*function\s+(?:[^=]+=\s*)?(\w+)"#),
        Language(name: "Nim", lexer: "nim", extensions: ["nim", "nims"], keywords: [nimKeywords], lineComment: "#"),
        Language(name: "NSIS", lexer: "nsis", extensions: ["nsi", "nsh"], lineComment: ";"),
        Language(name: "Objective-C", lexer: "cpp", extensions: ["m", "mm"], keywords: [cKeywords + " @interface @implementation @end @property @synthesize @protocol @class @selector @autoreleasepool self super nil YES NO id instancetype nonatomic strong weak copy assign readonly readwrite"],
                 lineComment: "//", blockComment: cLike, functionPattern: #"^[-+][ \t]*\([^)]*\)[ \t]*(\w+)"#),
        Language(name: "Pascal", lexer: "pascal", extensions: ["pas", "pp", "inc", "dpr", "lpr"], keywords: [pascalKeywords], lineComment: "//", blockComment: ("{", "}"),
                 functionPattern: #"(?i)^[ \t]*(?:procedure|function|constructor|destructor)[ \t]+([\w.]+)"#),
        Language(name: "Perl", lexer: "perl", extensions: ["pl", "pm", "t"], shebang: ["perl"], keywords: [perlKeywords], lineComment: "#", functionPattern: #"^[ \t]*sub[ \t]+(\w+)"#),
        Language(name: "PHP", lexer: "hypertext", extensions: ["php", "php3", "php4", "php5", "phtml", "phps"], shebang: ["php"],
                 keywords: [htmlTags, jsKeywords, "", "", phpKeywords], lineComment: "//", blockComment: cLike,
                 functionPattern: #"function[ \t]+&?(\w+)[ \t]*\("#),
        Language(name: "PowerShell", lexer: "powershell", extensions: ["ps1", "psm1", "psd1"], shebang: ["pwsh"], keywords: [powershellKeywords], lineComment: "#",
                 blockComment: ("<#", "#>"), functionPattern: #"(?i)^[ \t]*function[ \t]+([\w-]+)"#),
        Language(name: "Python", lexer: "python", extensions: ["py", "pyw", "pyi", "pyx", "gyp"], fileNames: ["sconstruct", "sconscript"], shebang: ["python"],
                 keywords: [pythonKeywords, pythonBuiltins], lineComment: "#", functionPattern: #"^[ \t]*(?:async[ \t]+)?(?:def|class)[ \t]+(\w+)"#,
                 properties: ["fold.quotes.python": "1"]),
        Language(name: "R", lexer: "r", extensions: ["r", "rdata", "rds", "rprofile"], keywords: [rKeywords], lineComment: "#", functionPattern: #"(\w+)[ \t]*<-[ \t]*function"#),
        Language(name: "Raku", lexer: "raku", extensions: ["raku", "rakumod", "p6"], lineComment: "#"),
        Language(name: "Registry", lexer: "registry", extensions: ["reg"], lineComment: ";"),
        Language(name: "Ruby", lexer: "ruby", extensions: ["rb", "rbw", "rake", "gemspec"], fileNames: ["rakefile", "gemfile", "podfile", "fastfile"], shebang: ["ruby"],
                 keywords: [rubyKeywords], lineComment: "#", functionPattern: #"^[ \t]*(?:def|class|module)[ \t]+([\w.?!]+)"#),
        Language(name: "Rust", lexer: "rust", extensions: ["rs"], keywords: [rustKeywords, rustTypes], lineComment: "//", blockComment: cLike,
                 functionPattern: #"\bfn[ \t]+(\w+)"#),
        Language(name: "Scala", lexer: "cpp", extensions: ["scala", "sc", "sbt"], keywords: [scalaKeywords], lineComment: "//", blockComment: cLike,
                 functionPattern: #"\bdef[ \t]+(\w+)"#),
        Language(name: "Shell", lexer: "bash", extensions: ["sh", "bash", "zsh", "ksh", "command", "fish"],
                 fileNames: [".bashrc", ".bash_profile", ".zshrc", ".zprofile", ".profile", ".zshenv"], shebang: ["sh", "bash", "zsh", "ksh"],
                 keywords: [bashKeywords], lineComment: "#", functionPattern: #"^[ \t]*(?:function[ \t]+)?([\w-]+)[ \t]*\(\)"#),
        Language(name: "Smalltalk", lexer: "smalltalk", extensions: ["st"]),
        Language(name: "SQL", lexer: "sql", extensions: ["sql"], keywords: [sqlKeywords, sqlTypes], lineComment: "--", blockComment: cLike,
                 functionPattern: #"(?i)create[ \t]+(?:or[ \t]+replace[ \t]+)?(?:table|view|procedure|function|trigger|index)[ \t]+(?:if[ \t]+not[ \t]+exists[ \t]+)?([\w.\[\]"`]+)"#,
                 properties: ["sql.backslash.escapes": "1"]),
        Language(name: "Swift", lexer: "cpp", extensions: ["swift"], keywords: [swiftKeywords, swiftTypes], lineComment: "//", blockComment: cLike,
                 functionPattern: #"\b(?:func|init|class|struct|enum|protocol|extension|actor)[ \t]+([\w.]+|init)"#),
        Language(name: "Tcl", lexer: "tcl", extensions: ["tcl", "tk"], keywords: [tclKeywords], lineComment: "#", functionPattern: #"^[ \t]*proc[ \t]+([\w:]+)"#),
        Language(name: "TOML", lexer: "toml", extensions: ["toml"], fileNames: ["cargo.lock", "pipfile"], lineComment: "#", functionPattern: #"^\[+([^\]]+)\]+"#),
        Language(name: "TypeScript", lexer: "cpp", extensions: ["ts", "tsx", "mts", "cts"], keywords: [tsKeywords], lineComment: "//", blockComment: cLike,
                 functionPattern: #"(?:^|[ \t])(?:function[ \t]*\*?[ \t]+(\w+)|(\w+)[ \t]*[:=][ \t]*(?:async[ \t]+)?(?:function\b|\([^)]*\)[ \t]*=>))"#,
                 properties: ["lexer.cpp.backquoted.strings": "1"]),
        Language(name: "Verilog", lexer: "verilog", extensions: ["v", "sv", "vh", "svh"], lineComment: "//", blockComment: cLike),
        Language(name: "VHDL", lexer: "vhdl", extensions: ["vhd", "vhdl"], lineComment: "--"),
        Language(name: "Visual Basic", lexer: "vb", extensions: ["vb", "bas", "frm", "cls", "vba"], keywords: [vbKeywords], lineComment: "'",
                 functionPattern: #"(?i)^[ \t]*(?:(?:public|private|friend|protected|shared|static)[ \t]+)*(?:sub|function|property[ \t]+(?:get|let|set))[ \t]+(\w+)"#),
        Language(name: "VBScript", lexer: "vbscript", extensions: ["vbs"], keywords: [vbKeywords], lineComment: "'"),
        Language(name: "XML", lexer: "xml", extensions: ["xml", "xsl", "xslt", "xsd", "svg", "plist", "xaml", "csproj", "vcxproj", "props", "targets", "storyboard", "xib", "rss", "kml", "gpx", "config", "resx", "nuspec"],
                 blockComment: ("<!--", "-->"), properties: ["fold.html": "1"]),
        Language(name: "YAML", lexer: "yaml", extensions: ["yml", "yaml"], lineComment: "#", functionPattern: #"^([\w.\-]+):"#),
        Language(name: "Zig", lexer: "zig", extensions: ["zig"], keywords: [zigKeywords], lineComment: "//", functionPattern: #"\bfn[ \t]+(\w+)"#),
    ]
}
