"""Support code for the *Modern Fortran for a Python/HPC Programmer* notebook.

The only thing exported is a gfortran-backed ``%%fortran`` cell magic.  Load it
with::

    %load_ext fortran_tour

See :mod:`fortran_tour.magic` for what the magic actually does.
"""

from fortran_tour.magic import FortranMagics, load_ipython_extension

__all__ = ["FortranMagics", "load_ipython_extension"]
__version__ = "0.1.0"
