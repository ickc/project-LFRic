--- Relabel `%%fortran` cells so Quarto highlights them as Fortran.
---
--- The notebook runs on a Python kernel that drives gfortran through a cell
--- magic (see `src/fortran_tour/magic.py`), so Quarto's Jupyter engine tags
--- every input cell with the kernel language, `python`.  For the cells whose
--- body is Fortran that is the wrong lexer — `!` comments come out unstyled
--- and none of the declaration keywords are recognised.
---
--- Declared from the notebook's own front matter, so it touches nothing else
--- in the site.

--- Swap one class for another, dropping it entirely when `to` is nil.
local function relabel(el, from, to)
  local classes = pandoc.List({})
  for _, c in ipairs(el.classes) do
    if c == from then
      if to then classes:insert(to) end
    else
      classes:insert(c)
    end
  end
  el.classes = classes
  return el
end

function CodeBlock(el)
  if not el.classes:includes("python") then
    return nil
  end
  -- `%` is the Lua pattern escape, so a literal `%%` is written `%%%%`.
  if el.text:match("^%%%%fortran_file") then
    -- Namelists and other data files: no lexer fits, so plain text.
    return relabel(el, "python", nil)
  elseif el.text:match("^%%%%fortran") then
    return relabel(el, "python", "fortran")
  end
  return nil
end
