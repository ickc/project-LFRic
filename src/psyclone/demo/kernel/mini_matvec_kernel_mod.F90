!-----------------------------------------------------------------------------
! A minimal but *real* LFRic kernel: the metadata below is what PSyclone
! actually reads, and the argument list is what PSyclone actually generates a
! call to.  Nothing here is a simplification of the interface -- only of the
! science.
!
! The counterpart in the Fortran tour (src/fortran/demo/mini_matvec_kernel_mod.f90)
! is the same computation with a hand-written PSy layer around it.  This one
! has PSyclone write that layer instead.
!-----------------------------------------------------------------------------
module mini_matvec_kernel_mod

  use argument_mod,      only : arg_type,          &
                                GH_FIELD, GH_REAL, &
                                GH_READ, GH_INC,   &
                                CELL_COLUMN
  use fs_continuity_mod, only : W1, W3
  use kernel_mod,        only : kernel_type
  use constants_mod,     only : i_def, r_def

  implicit none

  private

  !> @brief Applies a cell-local mass matrix, accumulating into a W1 field.
  !>
  !> The three lines of metadata are the entire contract with PSyclone:
  !>
  !>  - GH_INC on W1 says this kernel *increments* a field on a continuous
  !>    space. Continuous means neighbouring cells share degrees of freedom,
  !>    so two threads working on adjacent cells would race on the same
  !>    entry of lhs -- which is why an optimisation script has to colour
  !>    the mesh before it may add `!$omp parallel do` over cells.
  !>  - GH_READ on W3 is a discontinuous read, which constrains nothing.
  !>  - operates_on = CELL_COLUMN says the kernel is handed one vertical
  !>    column of one cell, and PSyclone owns the loop over cells.
  type, extends(kernel_type) :: mini_matvec_kernel_type
    private
    type(arg_type) :: meta_args(2) = (/                &
         arg_type(GH_FIELD, GH_REAL, GH_INC,  W1),     &
         arg_type(GH_FIELD, GH_REAL, GH_READ, W3)      &
         /)
    integer :: operates_on = CELL_COLUMN
  contains
    procedure, nopass :: mini_matvec_code
  end type mini_matvec_kernel_type

  public :: mini_matvec_kernel_type, mini_matvec_code

contains

  !> @details The argument list is not free: PSyclone derives it from the
  !>          metadata, in a fixed order -- nlayers, then the field arrays in
  !>          meta_args order, then per-function-space (ndf, undf, dofmap).
  !>          `psyclone-kern -gen stub` prints exactly this interface, which
  !>          is how you check a hand-written kernel agrees with its own
  !>          metadata.
  subroutine mini_matvec_code(nlayers,               &
                              lhs, rhs,              &
                              ndf_w1, undf_w1, map_w1, &
                              ndf_w3, undf_w3, map_w3)

    implicit none

    integer(kind=i_def), intent(in) :: nlayers
    integer(kind=i_def), intent(in) :: ndf_w1, undf_w1
    integer(kind=i_def), intent(in) :: ndf_w3, undf_w3
    integer(kind=i_def), dimension(ndf_w1), intent(in) :: map_w1
    integer(kind=i_def), dimension(ndf_w3), intent(in) :: map_w3
    real(kind=r_def), dimension(undf_w1), intent(inout) :: lhs
    real(kind=r_def), dimension(undf_w3), intent(in)    :: rhs

    integer(kind=i_def) :: k, df1, df3

    ! A stand-in for the cell-local matrix-vector product: every W1 dof of
    ! the column accumulates a weighted sum of the column's W3 dofs.  The
    ! `+` on the left is the whole point of GH_INC -- the kernel adds to
    ! whatever a neighbouring cell already contributed.
    do k = 0, nlayers - 1
      do df1 = 1, ndf_w1
        do df3 = 1, ndf_w3
          lhs(map_w1(df1) + k) = lhs(map_w1(df1) + k) &
                               + 0.5_r_def * rhs(map_w3(df3) + k)
        end do
      end do
    end do

  end subroutine mini_matvec_code

end module mini_matvec_kernel_mod
