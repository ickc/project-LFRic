# -----------------------------------------------------------------------------
# A teaching-sized version of lfric_core's
# infrastructure/build/psyclone/psyclone_tools.py, laid out so that the three
# decisions are visible in twenty lines rather than two hundred.
#
# The file name and location are not free.  The LFRic build system looks for
# `<optimisation-path>/psykal/global.py` (a whole-application script) or
# `<optimisation-path>/psykal/<algorithm-name>.py` (a per-file override), and
# passes whichever it finds to `psyclone -s`.  PSyclone then imports the file
# and calls the single function `trans` with the PSyIR of the PSy layer.
# -----------------------------------------------------------------------------
"""Colour, then parallelise, the loops in the generated PSy layer."""

from psyclone.domain.lfric import LFRicConstants
from psyclone.psyGen import InvokeSchedule
from psyclone.psyir.nodes import Directive, Loop
from psyclone.psyir.transformations import OMPParallelTrans
from psyclone.transformations import LFRicColourTrans, LFRicOMPLoopTrans


def trans(psyir):
    """Entry point. PSyclone calls this with the PSy layer's PSyIR.

    :param psyir: the PSyIR of the PSy-layer.
    :type psyir: :py:class:`psyclone.psyir.nodes.FileContainer`
    """
    const = LFRicConstants()
    colour = LFRicColourTrans()
    omp_region = OMPParallelTrans()
    omp_loop = LFRicOMPLoopTrans()

    for schedule in psyir.walk(InvokeSchedule):
        # 1. Colour every loop over cells on a *continuous* function space.
        #    Discontinuous spaces (W3, Wtheta) need no colouring -- no two
        #    cells share a dof, so there is no race to avoid -- and loops
        #    over dofs are not over cells at all.
        for loop in schedule.walk(Loop):
            if (
                loop.iteration_space.endswith("cell_column")
                and loop.field_space.orig_name
                not in const.VALID_DISCONTINUOUS_NAMES
            ):
                colour.apply(loop)

        # 2. Parallelise. After colouring, the loop nest is
        #    `do colour / do cell-in-colour`, and it is the *inner* loop that
        #    is safe to thread -- which is why the `loop_type == "colours"`
        #    outer loop is skipped rather than parallelised.
        for loop in schedule.loops():
            if loop.loop_type not in ("colours", "null") and not loop.ancestor(
                Directive
            ):
                omp_region.apply(loop)
                omp_loop.apply(loop, options={"reprod": True})
