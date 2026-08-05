!> @brief A kernel: metadata plus a loop over one column.
!>
!> @details Modelled line-for-line on
!>          `lfric_core/components/science/source/kernel/algebra/matrix_vector_kernel_mod.F90`,
!>          which computes the same thing (`lhs = lhs + A x`) on the real
!>          thing. Read the two side by side.
!>
!>          The shape of a kernel module is always this:
!>
!>          1. a derived type extending `kernel_type`, holding a `meta_args`
!>             array and an `operates_on` — this is read by PSyclone and never
!>             executed;
!>          2. a plain subroutine, the `_code` procedure, which is the science.
!>
!>          The `_code` subroutine takes only intrinsic types and explicit
!>          extents. No derived types, no `use` of model state, no allocation,
!>          no I/O, no `stop`. It handles one cell column and does not know
!>          that any other cell exists — so it is safe to run anywhere, on any
!>          thread, on a GPU. That restraint is what buys LFRic its
!>          performance portability, and it is enforced by review, not by the
!>          compiler.
module mini_matvec_kernel_mod

  use mini_argument_mod,  only : arg_type, kernel_type,           &
                                GH_FIELD, GH_OPERATOR, GH_REAL,   &
                                GH_READ, GH_INC,                  &
                                ANY_SPACE_1, ANY_SPACE_2,         &
                                CELL_COLUMN
  use mini_constants_mod, only : i_def, r_def

  implicit none

  private
  public :: matvec_kernel_type, matvec_code

  !> Metadata. Declared, never instantiated, never read at run time.
  type, public, extends(kernel_type) :: matvec_kernel_type
    private
    type(arg_type) :: meta_args(3) = (/                                        &
         arg_type(GH_FIELD,    GH_REAL, GH_INC,  ANY_SPACE_1),                 &
         arg_type(GH_FIELD,    GH_REAL, GH_READ, ANY_SPACE_2),                 &
         arg_type(GH_OPERATOR, GH_REAL, GH_READ, ANY_SPACE_1, ANY_SPACE_2)     &
         /)
    integer :: operates_on = CELL_COLUMN
  end type matvec_kernel_type

contains

  !> @brief Computes lhs = lhs + matrix*x for one cell.
  !> @param[in]    cell     Index of the cell being handled
  !> @param[inout] lhs      Field the kernel increments
  !> @param[in]    x        Field the kernel reads
  !> @param[in]    ncell    Total number of cells, the operator's first extent
  !> @param[in]    matrix   Cell-local matrices of the operator
  !> @param[in]    ndf1     Dofs per cell for lhs
  !> @param[in]    undf1    Unique dofs for lhs
  !> @param[in]    map1     Dofmap of this cell for lhs
  !> @param[in]    ndf2     Dofs per cell for x
  !> @param[in]    undf2    Unique dofs for x
  !> @param[in]    map2     Dofmap of this cell for x
  subroutine matvec_code(cell,              &
                         lhs, x,            &
                         ncell, matrix,     &
                         ndf1, undf1, map1, &
                         ndf2, undf2, map2)

    implicit none

    integer(i_def), intent(in) :: cell, ncell
    integer(i_def), intent(in) :: ndf1, undf1
    integer(i_def), intent(in) :: ndf2, undf2
    integer(i_def), intent(in) :: map1(ndf1)
    integer(i_def), intent(in) :: map2(ndf2)

    ! Explicit-shape dummies: the caller supplies the extents, so the compiler
    ! knows these are contiguous and can address them without a descriptor.
    ! This is the same bargain as declaring `float64[::1]` to Numba.
    real(r_def), intent(inout) :: lhs(undf1)
    real(r_def), intent(in)    :: x(undf2)
    real(r_def), intent(in)    :: matrix(ncell, ndf1, ndf2)

    integer(i_def) :: df1, df2

    ! `intent(inout)`, not `intent(out)`: a `GH_INC` kernel is called once per
    ! cell and each call touches only a few dofs of `lhs`. `intent(out)` would
    ! license the compiler to treat the rest as undefined.
    do df2 = 1, ndf2
      do df1 = 1, ndf1
        lhs(map1(df1)) = lhs(map1(df1)) + matrix(cell, df1, df2)*x(map2(df2))
      end do
    end do

  end subroutine matvec_code

end module mini_matvec_kernel_mod
