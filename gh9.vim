" gh9.vim - Ghq based Plugin Loader
" Version: 0.2.0
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
command! -nargs=0 GhqMessages  call s:message(s:INFO, 's:echo')
command! -complete=customlist,s:help_complete -nargs=* Help
      \ call s:cmd_help(<q-args>)
nnoremap <silent> K  :<C-u>call <SID>map_tryhelp("<C-r><C-w>")<CR>

function! gh9#begin(...)
  for a in a:000
    if type(a) == type('')
      let dir = a
    elseif type(a) == type({})
      let dump = a
    endif
  endfor
  if exists('dump') && s:validate_dump(dump)
    command! -buffer -nargs=+ Ghq  call s:cmd_nop()
    command! -buffer -nargs=1 -complete=dir GhqGlob  call s:cmd_nop()
    let s:repos = dump.repos
    let s:_dirs = dump.dirs
    let s:_plugins = dump.plugins
    let s:_ftdetects = dump.ftdetects
    let s:_commands = dump.commands
  else
    command! -buffer -nargs=+ Ghq  call s:cmd_bundle(<args>)
    command! -buffer -nargs=1 -complete=dir GhqGlob  call s:cmd_globlocal(<args>)
  endif
  call s:cmd_init(exists('dir') ? dir : [])
endfunction

function! gh9#end(...)
  delcommand Ghq
  delcommand GhqGlob
  call s:cmd_apply(a:0 ? a:1 : {})
endfunction

function! s:validate_dump(dict)
  return has_key(a:dict, 'repos') && type(a:dict.repos) == type({})
        \ && has_key(a:dict, 'dirs') && type(a:dict.dirs) == type([])
        \ && has_key(a:dict, 'plugins') && type(a:dict.plugins) == type([])
        \ && has_key(a:dict, 'ftdetects') && type(a:dict.ftdetects) == type([])
        \ && has_key(a:dict, 'commands') && type(a:dict.commands) == type([])
endfunction

function! gh9#dump()
  let repos = deepcopy(s:repos)
  for key in keys(repos)
    if has_key(repos[key], '__loaded')
      call remove(repos[key], '__loaded')
    endif
  endfor
  return string({'repos': repos, 'dirs': s:_dirs, 'plugins': s:_plugins, 'ftdetects': s:_ftdetects, 'commands': s:_commands})
endfunction

function! gh9#tap(bundle)
  if !has_key(s:repos, a:bundle)
    let msg = printf('no repository found on gh9#tap("%s")', a:bundle)
    if has('vim_starting')
      call s:log(s:WARNING, msg)
    else
      echohl WarningMsg | echomsg msg | echohl NONE
    endif
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

  if !exists('s:_dirs')
    let s:_dirs = []
    let s:_ftdetects = []
    let s:_plugins = []
    let s:_commands = []
    for [name, params] in items(s:repos)
      call extend(params, a:config, 'keep')
      let path = has_key(params, 'rtp') ? join([path, params.rtp], '/') : s:get_path(name)
      if empty(path) || !get(params, 'enabled', 1)
        continue
      endif

      if has_key(params, 'filetype')
        let s:_ftdetects += s:globpath(path, 'ftdetect/**/*.vim')
      endif

      let preload = has_key(params, 'preload') ? params.preload : 0
      let triggered = 0
      if has_key(params, 'filetype') || has_key(params, 'autoload')
        let s:_plugins += preload ? s:get_preloads(path) : []
        let triggered = 1
      endif
      if has_key(params, 'command')
        let s:_commands += [[params.command, name]]
        let triggered = 1
      endif
      if !triggered
        let s:_dirs += [path]
        let params.__loaded = 1
      endif
    endfor
  endif
  call s:set_runtimepath(s:_dirs)
  call s:source_scripts(s:_ftdetects)
  for [cmd, name] in s:_commands
    call s:define_pseudo_commands(cmd, name)
    unlet cmd
  endfor

  augroup plugin_gh9
    autocmd!
    autocmd FileType *  call s:on_filetype(expand('<amatch>'))
    autocmd FuncUndefined *  call s:on_funcundefined(expand('<amatch>'))
    if !empty(s:_plugins)
      autocmd VimEnter *  call s:on_vimenter()
    endif
  augroup END

  if has('vim_starting')
    return
  endif
  for path in split(&runtimepath, ',')
    call s:source_scripts(s:get_preloads(path))
  endfor
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
  catch /^Vim\%((\a\+)\)\=:E149/
    echohl WarningMsg | echomsg 'gh9: Sorry, no help for ' . a:term | echohl NONE
  finally
    let &rtp = rtp
  endtry
endfunction

function! s:cmd_nop()
endfunction

function! s:map_tryhelp(word)
  try
    execute 'help' a:word
  catch /^Vim\%((\a\+)\)\=:E149/
    execute 'Help' a:word
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
  call s:source_scripts(s:_plugins)
  if !empty(s:log)
    call s:message(s:WARNING, 's:echomsg_warning')
  endif
endfunction "}}}

function! s:on_funcundefined(funcname) "{{{
  let dirs = []
  for [name, params] in items(s:repos)
    if !get(params, 'enabled', 1) || get(params, '__loaded', 0) || !has_key(params, 'autoload')
      continue
    endif
    if stridx(a:funcname , params.autoload) == 0
      call s:log(s:INFO, printf('loading %s on autoload[%s] (%s)', name, params.autoload, a:funcname))
      let dirs += [s:get_path(name)]
      let params.__loaded = 1
    endif
  endfor
  call s:inject_runtimepath(dirs)
endfunction "}}}

function! s:on_filetype(filetype) "{{{
  let dirs = []
  for [name, params] in items(s:repos)
    if !get(params, 'enabled', 1) || get(params, '__loaded', 0) || !has_key(params, 'filetype')
      continue
    endif
    if s:included(params.filetype, a:filetype)
      call s:log(s:INFO, printf('loading %s on filetype[%s]', name, a:filetype))
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
  for [name, params] in items(s:repos)
    for key in keys(params)
      if index(validation_keys, key) == -1
        echohl ErrorMsg | echomsg 'Invalid Key:' name key | echohl NONE
      endif
    endfor
  endfor
endfunction "}}}

" RTP {{{2
function! s:source_scripts(paths)
  for path in a:paths
    source `=path`
  endfor
endfunction

function! s:inject_runtimepath(dirs)
  let &runtimepath = s:rtp_generate(a:dirs)
  for plugin_path in s:globpath(join(a:dirs,','), 'plugin/**/*.vim') + s:globpath(join(a:dirs,','), 'after/**/*.vim')
    execute 'source' plugin_path
  endfor
endfunction

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
  for plugin_path in s:globpath(a:name, 'plugin/**/*.vim')
    let _ += [plugin_path]
  endfor
  return _
endfunction

" Command {{{2
function! s:define_pseudo_commands(commands, name)
  let commands = type(a:commands) == type([]) ? a:commands : [a:commands]
  for command in commands
    if type(command) != type({}) | return | endif
    let cmd = command.name
    if has_key(command, 'bang')
      let bang = command.bang
    endif
    let attr = map(filter(copy(command), 'v:key isnot# "bang" && v:key isnot# "name"'), 'printf("-%s=%s", v:key, v:val)')
    execute 'command!' join(values(attr), ' ') (exists('bang') ? '-bang' : '') cmd printf('call s:pseudo_command(%s, %s, %s, %s)', string(a:name), string(cmd), exists('bang') ? '"!"' : '""', "<q-args>")
  endfor
endfunction

function! s:pseudo_command(name, cmd, bang, args)
  execute 'delcommand' a:cmd
  call s:log(s:INFO, printf('loading %s on command[%s]', a:name, a:cmd))
  call s:inject_runtimepath([s:get_path(a:name)])
  execute a:cmd . a:bang a:args
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

function! s:included(values, name) "{{{
  let values = type(a:values) == type('') ? [a:values] : a:values
  return len(filter(copy(values), 'a:name =~# v:val')) > 0
endfunction "}}}

function! s:log(level, msg)
  let s:log += [[a:level, localtime(), a:msg]]
endfunction

function! s:message(threshold, funcname)
  for [level, time, msg] in s:log
    if a:threshold >= level
      call call(a:funcname, [time, printf('[%s] %s', s:lvl2str(level), msg)])
    endif
  endfor
endfunction

function! s:echo(time, msg)
  execute 'echo' string(printf('%s| %s', strftime('%c', a:time), a:msg))
endfunction

function! s:echomsg_warning(time, msg)
  echohl WarningMsg | execute 'echomsg' string(a:msg) | echohl NONE
endfunction

let s:levels = ['WARNING', 'INFO']
let [s:WARNING, s:INFO] = range(len(s:levels))
function! s:lvl2str(level)
  return s:levels[a:level]
endfunction
" 1}}}

let s:repos = get(s:, 'repos', {})
let s:log = get(s:, 'log', [])

let &cpo = s:save_cpo
unlet s:save_cpo

" vim:set et:
