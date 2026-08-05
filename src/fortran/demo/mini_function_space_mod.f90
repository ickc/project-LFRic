!> @brief A function space, in miniature: a mesh plus a dof numbering.
!>
!> @details The mesh is the unit interval cut into `ncell` elements; the
!>          function space is continuous piecewise-linear, so the degrees of
!>          freedom are the `ncell + 1` nodes and neighbouring cells *share*
!>          the node between them. That sharing is the whole story: it is why
!>          the kernel's access is `GH_INC` rather than `GH_WRITE`, why a naive
!>          parallel loop over cells races, and why LFRic colours its mesh.
!>
!>          Vocabulary, which is LFRic's:
!>
!>          * `ndf`  — dofs per cell (2 here: the two ends of an element)
!>          * `undf` — unique dofs over the whole space (`ncell + 1`)
!>          * `dofmap(df, cell)` — local dof `df` of `cell` is global dof
!>            `dofmap(df, cell)`; the indirection that makes an unstructured
!>            mesh addressable
module mini_function_space_mod

  use mini_constants_mod, only : i_def, r_def

  implicit none

  private
  public :: function_space_type

  type :: function_space_type
    private
    integer(i_def) :: ncell = 0
    integer(i_def) :: ndf   = 2
    integer(i_def) :: undf  = 0
    real(r_def)    :: h     = 0.0_r_def
    integer(i_def), allocatable :: dofmap(:,:)
  contains
    procedure, public :: initialise => function_space_initialiser
    procedure, public :: get_ncell
    procedure, public :: get_ndf
    procedure, public :: get_undf
    procedure, public :: get_cell_width
    procedure, public :: get_cell_dofmap
  end type function_space_type

contains

  !> @brief Set up the space over `ncell` elements of the unit interval.
  !> @param[inout] self  The function space
  !> @param[in]    ncell Number of cells
  subroutine function_space_initialiser(self, ncell)

    implicit none

    class(function_space_type), intent(inout) :: self
    integer(i_def),             intent(in)    :: ncell

    integer(i_def) :: cell

    self%ncell = ncell
    self%ndf   = 2_i_def
    self%undf  = ncell + 1_i_def
    self%h     = 1.0_r_def / real(ncell, r_def)

    allocate( self%dofmap(self%ndf, ncell) )
    do cell = 1, ncell
      self%dofmap(1, cell) = cell
      self%dofmap(2, cell) = cell + 1_i_def
    end do

  end subroutine function_space_initialiser

  !> @brief Number of cells.
  !> @param[in] self The function space
  !> @return ncell The cell count
  pure function get_ncell(self) result(ncell)
    implicit none
    class(function_space_type), intent(in) :: self
    integer(i_def) :: ncell
    ncell = self%ncell
  end function get_ncell

  !> @brief Degrees of freedom per cell.
  !> @param[in] self The function space
  !> @return ndf The per-cell dof count
  pure function get_ndf(self) result(ndf)
    implicit none
    class(function_space_type), intent(in) :: self
    integer(i_def) :: ndf
    ndf = self%ndf
  end function get_ndf

  !> @brief Unique degrees of freedom over the whole space.
  !> @param[in] self The function space
  !> @return undf The unique dof count
  pure function get_undf(self) result(undf)
    implicit none
    class(function_space_type), intent(in) :: self
    integer(i_def) :: undf
    undf = self%undf
  end function get_undf

  !> @brief Width of one element.
  !> @param[in] self The function space
  !> @return h The element width
  pure function get_cell_width(self) result(h)
    implicit none
    class(function_space_type), intent(in) :: self
    real(r_def) :: h
    h = self%h
  end function get_cell_width

  !> @brief The dof indices of one cell.
  !> @param[in] self The function space
  !> @param[in] cell Which cell
  !> @return map The global dof index of each of the cell's local dofs
  pure function get_cell_dofmap(self, cell) result(map)
    implicit none
    class(function_space_type), intent(in) :: self
    integer(i_def),             intent(in) :: cell
    integer(i_def) :: map(self%ndf)
    map = self%dofmap(:, cell)
  end function get_cell_dofmap

end module mini_function_space_mod
