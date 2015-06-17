" gh9.vim - Ghq based Plugin Loader
" Version: 0.1.0
" Author: sgur <sgurrr@gmail.com>
" License: MIT License

scriptencoding utf-8

let s:save_cpo = &cpo
set cpo&vim

if exists('g:loaded_gh9') && g:loaded_gh9
  finish
endif
let g:loaded_gh9 = 1


" Interfaces {{{1
command! -nargs=0 GhqRepos call s:cmd_dump()
command! -nargs=0 Helptags  call s:cmd_helptags()
command! -nargs=0 GhqMessages  echo join(s:log, "\n")
command! -complete=customlist,s:help_complete -nargs=* Help
      \ call s:cmd_help(<q-args>)

function! gh9#begin(...)
  command! -buffer -nargs=+ Ghq  call s:cmd_bundle(<args>)
  command! -buffer -nargs=1 -complete=dir GhqGlob  call s:cmd_globlocal(<args>)
  call s:cmd_init(a:000)
endfunction

function! gh9#end(...)
  delcommand Ghq
  delcommand GhqGlob
  call s:cmd_apply(a:0 ? a:1 : {})
endfunction

function! gh9#tap(bundle)
  if !has_key(s:repos, a:bundle)
    throw 'gh9#tap(): no repository (' . a:bundle . ')'
    return 0
  endif
  if !&loadplugins | return 0 | endif

  if isdirectory(s:get_path(a:bundle)) && get(s:repos[a:bundle], 'enabled', 1)
    return 1
  endif
  return 0
endfunction

function! gh9#repos(...)
  return deepcopy(a:0 > 0 ? s:repos[a:1] : s:repos)
endfunction

" Internals {{{1
" Commands {{{2
function! s:cmd_init(dirs) "{{{
  if !exists('s:rtp') | let s:rtp = &runtimepath | endif
  let s:ghq_root = !empty(a:dirs) ? a:dirs[0] : s:find_ghq_root()
endfunction "}}}

function! s:cmd_bundle(bundle, ...) "{{{
  if empty(a:bundle) | return | endif
  let repo = !a:0 ? {} : (!empty(a:1) && type(a:1) == type({}) ? a:1 : {})
  let s:repos[a:bundle] = repo
  if get(repo, 'immediately', 0)
    let &runtimepath .= ',' . s:get_path(a:bundle)
  endif
endfunction "}}}

function! s:cmd_globlocal(...) "{{{
  if !isdirectory(expand(a:1))
    echohl WarningMsg | echomsg 'Not found:' a:1 | echohl NONE
    return
  endif
  for dir in s:globpath(a:1, '*')
    if has_key(s:repos, dir) || dir =~# '\~$'
      continue
    endif
    let s:repos[dir] = {}
  endfor
endfunction "}}}

function! s:cmd_apply(config) "{{{
  if !&loadplugins | return | endif

  let dirs = []
  let ftdetects = []
  let s:_plugins = []
  for repo in items(s:repos)
    let name = s:get_path(repo[0])
    if empty(name) || !get(repo[1], 'enabled', 1)
      continue
    endif
    if has_key(repo[1], 'rtp')
      let name = join([name, repo[1].rtp], '/')
    endif
    let preload = has_key(repo[1], 'preload')
          \ ? repo[1].preload
          \ : has_key(a:config, 'preload') ? a:config.preload : 0
    if has_key(repo[1], 'filetype')
      let ftdetects += s:globpath(name, 'ftdetect/**/*.vim')
      if preload
        let s:_plugins += s:get_preloads(name)
      endif
    elseif has_key(repo[1], 'autoload')
      if preload
        let s:_plugins += s:get_preloads(name)
      endif
    else
      let dirs += [name]
      let repo[1].__loaded = 1
    endif
  endfor
  call s:set_runtimepath(dirs)
  for ftdetect in ftdetects
    source `=ftdetect`
  endfor

  augroup plugin_gh9
    autocmd!
    autocmd FileType *  call s:on_filetype(expand('<amatch>'))
    autocmd FuncUndefined *  call s:on_funcundefined(expand('<amatch>'))
    if !empty(s:_plugins)
      autocmd VimEnter *  call s:on_vimenter()
    endif
  augroup END
endfunction "}}}

function! s:cmd_helptags() "{{{
  let dirs = filter(map(keys(s:repos), 'expand(s:get_path(v:val) . "/doc")'), 'isdirectory(v:val)')
  echohl Title | echo 'helptags:' | echohl NONE
  for dir in filter(dirs, 'filewritable(v:val) == 2')
    echon ' ' . fnamemodify(dir, ':h:t')
    execute 'helptags' dir
  endfor
endfunction "}}}

function! s:cmd_dump() "{{{
  new
  setlocal buftype=nofile
  call append(0, keys(filter(deepcopy(s:repos), '!isdirectory(v:key) && !get(v:val, "pinned", 0)')))
  normal! Gdd
  execute '%print'
  bdelete
endfunction "}}}

function! s:cmd_help(term)
  let rtp = &rtp
  try
    let &rtp = join(map(values(s:repos), 'v:val.__path'),',')
    execute 'help' a:term
    nnoremap <silent> <buffer> K :<C-u>Help <C-r><C-w><CR>
  finally
    let &rtp = rtp
  endtry
endfunction

" Completion {{{2
function! s:help_complete(arglead, cmdline, cursorpos) "{{{
  let tags = &l:tags
  try
    if !exists('s:tagdirs')
      let s:tagdirs = join(filter(map(values(s:repos), 'v:val.__path . "/doc/tags"'), 'filereadable(v:val)'),',')
    endif
    let &l:tags = s:tagdirs
    return map(taglist(empty(a:arglead)? '.' : a:arglead), 'v:val.name')
  finally
    let &l:tags = tags
  endtry
endfunction "}}}

" Autocmd Events {{{2
function! s:on_vimenter() "{{{
  autocmd! plugin_gh9 VimEnter *
  if !exists('s:_plugins')
    return
  endif
  for path in s:_plugins
    source `=path`
  endfor
endfunction "}}}

function! s:on_funcundefined(funcname) "{{{
  let dirs = []
  for repo in items(s:repos)
    let [name, params] = [repo[0], repo[1]]
    if !get(params, 'enabled', 1) || get(params, '__loaded', 0) || !has_key(params, 'autoload')
      continue
    endif
    if stridx(a:funcname , params.autoload) > -1
      call s:log(printf('[DEBUG] on autoload function %s (%s) -> %s', params.autoload, a:funcname, name))
      let dirs += [s:get_path(name)]
      let params.__loaded = 1
    endif
  endfor
  let &runtimepath = s:rtp_generate(dirs)
  for plugin_path in s:globpath(join(dirs,','), 'plugin/**/*.vim') + s:globpath(join(dirs,','), 'after/**/*.vim')
    execute 'source' plugin_path
  endfor
endfunction "}}}

function! s:on_filetype(filetype) "{{{
  let dirs = []
  for repo in items(s:repos)
    let [name, params] = [repo[0], repo[1]]
    if !get(params, 'enabled', 1) || get(params, '__loaded', 0) || !has_key(params, 'filetype')
      continue
    endif
    if s:included(params.filetype, a:filetype)
      call s:log(printf('[DEBUG] on filetype %s -> %s', a:filetype, name))
      let dirs += [s:get_path(name)]
      let params.__loaded = 1
    endif
  endfor
  let &runtimepath = s:rtp_generate(dirs)
  for plugin_path in s:globpath(join(dirs,','), 'plugin/**/*.vim')
    execute 'source' plugin_path
  endfor
endfunction "}}}

" Repos {{{2
function! s:find_ghq_root()
  let gitconfig = readfile(expand('~/.gitconfig'))
  let ghq_root = filter(map(gitconfig, 'matchstr(v:val, ''root\s*=\s*\zs.*'')'), 'v:val isnot""')
  return ghq_root[0]
endfunction

function! s:get_path(name) " {{{
  let repo = get(s:repos, a:name, {})
  if !has_key(repo, '__path')
    let repo.__path = s:find_path(a:name)
  endif
  return repo.__path
endfunction " }}}

function! s:find_path(name) "{{{
  let repo_name = s:repo_url(a:name)
  if isdirectory(repo_name)
    return repo_name
  endif
  let path = expand(join([s:ghq_root, repo_name], '/'))
  if isdirectory(path)
    return path
  endif
  return ''
endfunction "}}}

function! s:repo_url(name) "{{{
  return count(split(tr(a:name, '\', '/'), '\zs'), '/') == 1
        \ ? 'github.com/' . a:name
        \ : substitute(a:name, '^https\?://', '', '')
endfunction "}}}

function! s:validate_repos() "{{{
  let validation_keys = ['filetype', 'enabled', 'immediately', 'autoload', 'rtp', 'pinned', '__path', '__loaded']
  for repo in items(s:repos)
    for key in keys(repo[1])
      if index(validation_keys, key) == -1
        echohl ErrorMsg | echomsg 'Invalid Key:' repo[0] key | echohl NONE
      endif
    endfor
  endfor
endfunction "}}}

" RTP {{{2
function! s:set_runtimepath(dirs) "{{{
  if !exists('s:rtp')
    let s:rtp = &runtimepath
  endif
  let &runtimepath = s:rtp
  let &runtimepath = s:rtp_generate(a:dirs)
endfunction "}}}

function! s:rtp_generate(paths) "{{{
  let after_rtp = s:glob_after(join(a:paths, ','))
  let rtps = split(&runtimepath, ',')
  call extend(rtps, a:paths, 1)
  call extend(rtps, after_rtp, -1)
  return join(rtps, ',')
endfunction "}}}

function! s:glob_after(rtp) "{{{
  return s:globpath(a:rtp, 'after')
endfunction "}}}

function! s:get_preloads(name)
  let _ = []
  " for plugin_path in s:globpath(a:name, 'plugin/**/*.vim') + s:globpath(name, 'after/**/*.vim')
  for plugin_path in s:globpath(a:name, 'plugin/**/*.vim')
    let _ += [plugin_path]
  endfor
  return _
endfunction

" Misc {{{2
function! s:globpath(path, expr) "{{{
  return has('patch-7.4.279') ? globpath(a:path, a:expr, 0, 1) : split(globpath(a:path, a:expr, 1))
endfunction "}}}

function! s:systemlist(cmd) "{{{
  return exists('*systemlist') ? systemlist(a:cmd) : split(system(a:cmd), "\n")
endfunction "}}}

function! s:to_list(value) "{{{
  if type(a:value) == type([])
    return a:value
  else
    return [a:value]
  endif
endfunction "}}}

function! s:globpath(path, expr) "{{{
  return has('patch-7.4.279') ? globpath(a:path, a:expr, 1, 1) : split(globpath(a:path, a:expr, 1))
endfunction "}}}

function! s:included(values, name) "{{{
  let values = type(a:values) == type('') ? [a:values] : a:values
  return len(filter(copy(values), 'a:name =~# v:val')) > 0
endfunction "}}}

function! s:log(msg)
  let s:log += [join([strftime('%c'), a:msg], '| ')]
endfunction

" 1}}}

let s:repos = get(s:, 'repos', {})
let s:log = []

let &cpo = s:save_cpo
unlet s:save_cpo

" vim:set et:
