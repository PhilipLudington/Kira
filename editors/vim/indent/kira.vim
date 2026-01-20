" Vim indent file
" Language: Kira
" Maintainer: Kira Language Team

if exists("b:did_indent")
  finish
endif
let b:did_indent = 1

setlocal indentexpr=GetKiraIndent()
setlocal indentkeys=0{,0},0),!^F,o,O,e

if exists("*GetKiraIndent")
  finish
endif

function! GetKiraIndent()
  let lnum = prevnonblank(v:lnum - 1)
  if lnum == 0
    return 0
  endif

  let line = getline(lnum)
  let ind = indent(lnum)

  " Increase indent after opening brace
  if line =~ '{\s*$'
    let ind += shiftwidth()
  endif

  " Decrease indent for closing brace
  let cline = getline(v:lnum)
  if cline =~ '^\s*}'
    let ind -= shiftwidth()
  endif

  return ind
endfunction
