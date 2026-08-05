!> @brief The algorithm layer, in miniature.
!>
!> @details This is the layer a scientist writes, and the thing to notice is
!>          everything that is *not* here: no loop over cells, no dofmap, no
!>          index, no `!$omp`, no halo exchange, no mention of how many
!>          processes there are. Whole fields go in, whole fields come out.
!>
!>          In real LFRic this file would be `mini_alg_mod.x90` and the two
!>          calls below would be a single
!>
!>              call invoke( name = "apply_mass_matrix",   &
!>                           setval_c(lhs, 0.0_r_def),     &
!>                           matvec_kernel_type(lhs, x, mass_op) )
!>
!>          which PSyclone rewrites into `mini_alg_mod.f90` plus a generated
!>          PSy module. `setval_c` is a *built-in*: a kernel PSyclone knows how
!>          to write itself. Grouping both operations into one `invoke` is a
!>          coding standard, not a nicety — PSyclone can only fuse loops and
!>          elide halo exchanges within a single invoke, because that is all it
!>          can see the dependencies of.
module mini_alg_mod

  use mini_constants_mod,      only : i_def, r_def
  use mini_field_mod,          only : field_type, field_proxy_type
  use mini_function_space_mod, only : function_space_type
  use mini_psy_mod,            only : invoke_matvec, invoke_matvec_coloured

  implicit none

  private
  public :: apply_mass_matrix, build_mass_operator

contains

  !> @brief Apply the assembled mass matrix: `lhs = M x`.
  !> @param[inout] lhs      Result field
  !> @param[in]    x        Field to apply the operator to
  !> @param[in]    mass_op  Cell-local mass matrices
  !> @param[in]    threaded Use the coloured, threaded PSy routine
  subroutine apply_mass_matrix(lhs, x, mass_op, threaded)

    implicit none

    type(field_type), intent(inout) :: lhs
    type(field_type), intent(in)    :: x
    real(r_def),      intent(in)    :: mass_op(:,:,:)
    logical,          intent(in)    :: threaded

    ! Stands in for the built-in `setval_c(lhs, 0.0_r_def)`.
    call zero_field(lhs)

    if (threaded) then
      call invoke_matvec_coloured(lhs, x, mass_op)
    else
      call invoke_matvec(lhs, x, mass_op)
    end if

  end subroutine apply_mass_matrix

  !> @brief Zero a field. Stands in for PSyclone's `setval_c` built-in.
  !> @param[inout] field The field to zero
  subroutine zero_field(field)

    implicit none

    type(field_type), intent(inout) :: field

    type(field_proxy_type) :: proxy

    proxy = field%get_proxy()
    proxy%data(:) = 0.0_r_def

  end subroutine zero_field

  !> @brief Cell-local mass matrices for continuous piecewise-linear elements.
  !> @details On an element of width h the exact mass matrix is
  !>          (h/6)*[[2, 1], [1, 2]] — the Gram matrix of the two hat functions
  !>          restricted to the element.
  !> @param[in] fs The function space
  !> @return matrix Local matrices, indexed (cell, df1, df2)
  function build_mass_operator(fs) result(matrix)

    implicit none

    type(function_space_type), intent(in) :: fs
    real(r_def), allocatable :: matrix(:,:,:)

    integer(i_def) :: cell, ncell, ndf
    real(r_def)    :: h

    ncell = fs%get_ncell()
    ndf   = fs%get_ndf()
    h     = fs%get_cell_width()

    allocate( matrix(ncell, ndf, ndf) )
    do cell = 1, ncell
      matrix(cell, 1, 1) = 2.0_r_def*h/6.0_r_def
      matrix(cell, 1, 2) =       h/6.0_r_def
      matrix(cell, 2, 1) =       h/6.0_r_def
      matrix(cell, 2, 2) = 2.0_r_def*h/6.0_r_def
    end do

  end function build_mass_operator

end module mini_alg_mod
