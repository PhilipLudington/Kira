" Vim syntax file
" Language: Kira
" Maintainer: Kira Language Team
" Latest Revision: 2024

if exists("b:current_syntax")
  finish
endif

let b:current_syntax = "kira"

" Keywords
syn keyword kiraKeyword fn let var type module import pub effect trait impl const
syn keyword kiraControl if else match for return break
syn keyword kiraOperator and or not is in as where
syn keyword kiraSelf self Self

" Types
syn keyword kiraType i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f32 f64 bool char string void
syn keyword kiraBuiltinType Option Result List IO

" Boolean literals
syn keyword kiraBool true false

" Option/Result/List constructors
syn keyword kiraConstant Some None Ok Err Cons Nil

" Type names (PascalCase identifiers)
syn match kiraTypeName '\v<[A-Z][a-zA-Z0-9_]*>'

" Function calls
syn match kiraFunction '\v<[a-z_][a-zA-Z0-9_]*\ze\s*\('
syn match kiraFunction '\v<[a-z_][a-zA-Z0-9_]*\ze\s*\['

" Numbers
syn match kiraNumber '\v<\d+>'
syn match kiraNumber '\v<\d+[iu](8|16|32|64|128)>'
syn match kiraNumber '\v<\d+\.\d+>'
syn match kiraNumber '\v<\d+\.\d+f(32|64)>'
syn match kiraNumber '\v<0x[0-9a-fA-F_]+>'
syn match kiraNumber '\v<0b[01_]+>'

" Strings
syn region kiraString start='"' end='"' skip='\\"' contains=kiraEscape,kiraInterpolation
syn match kiraEscape contained '\\[nrt\\"0]'
syn region kiraInterpolation contained start='{' end='}' contains=TOP

" Characters
syn match kiraChar "'\(\\[nrt\\']\|[^'\\]\)'"

" Comments
syn match kiraDocComment '///.*$'
syn match kiraModuleDoc '//!.*$'
syn match kiraComment '//.*$'
syn region kiraBlockComment start='/\*' end='\*/'

" Operators
syn match kiraOperatorSym '\v\-\>'
syn match kiraOperatorSym '\v\=\>'
syn match kiraOperatorSym '\v\?\?'
syn match kiraOperatorSym '\v\?'
syn match kiraOperatorSym '\v\.\.'
syn match kiraOperatorSym '\v\.\.\='
syn match kiraOperatorSym '\v::'
syn match kiraOperatorSym '\v\|'
syn match kiraOperatorSym '\v\=\='
syn match kiraOperatorSym '\v!\='
syn match kiraOperatorSym '\v\<\='
syn match kiraOperatorSym '\v\>\='

" Highlighting
hi def link kiraKeyword Keyword
hi def link kiraControl Conditional
hi def link kiraOperator Operator
hi def link kiraSelf Special
hi def link kiraType Type
hi def link kiraBuiltinType Type
hi def link kiraBool Boolean
hi def link kiraConstant Constant
hi def link kiraTypeName Type
hi def link kiraFunction Function
hi def link kiraNumber Number
hi def link kiraString String
hi def link kiraChar Character
hi def link kiraEscape SpecialChar
hi def link kiraInterpolation Special
hi def link kiraDocComment SpecialComment
hi def link kiraModuleDoc SpecialComment
hi def link kiraComment Comment
hi def link kiraBlockComment Comment
hi def link kiraOperatorSym Operator
