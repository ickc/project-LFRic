!> @brief The kernel-metadata vocabulary, in miniature.
!>
!> @details These declarations are never executed and the values are never
!>          read at run time. They exist so that a kernel can *state*, in
!>          compilable Fortran, what it does to each of its arguments — and so
!>          that a source-to-source compiler (PSyclone, in LFRic's case) can
!>          read that statement out of the parse tree and generate the loop
!>          nest, the halo exchanges and the threading around it.
!>
!>          It is a domain-specific language whose host is Fortran's type
!>          system. The compiler checks that the metadata is well-formed
!>          Fortran; PSyclone checks that it is well-formed metadata.
!>
!>          Compare `lfric_core/infrastructure/source/kernel_metadata/`, where
!>          the enumerators have deliberately arbitrary values (`GH_FIELD =
!>          507`) precisely because nothing is ever meant to depend on them
!>          numerically.
module mini_argument_mod

  implicit none

  private
  public :: arg_type, kernel_type
  public :: GH_FIELD, GH_OPERATOR, GH_REAL
  public :: GH_READ, GH_WRITE, GH_INC
  public :: W0, ANY_SPACE_1, ANY_SPACE_2
  public :: CELL_COLUMN

  !> @name What kind of thing an argument is.
  !> @{
  integer, parameter :: GH_FIELD    = 507
  integer, parameter :: GH_OPERATOR = 735
  !> @}

  !> @name What the argument holds.
  !> @{
  integer, parameter :: GH_REAL = 58
  !> @}

  !> @name How the kernel touches it. `GH_INC` means "increment a shared
  !!       degree of freedom", which is the access that forces colouring.
  !> @{
  integer, parameter :: GH_READ  = 1
  integer, parameter :: GH_WRITE = 2
  integer, parameter :: GH_INC   = 3
  !> @}

  !> @name Which function space the argument lives on.
  !> @{
  integer, parameter :: W0          = 1
  integer, parameter :: ANY_SPACE_1 = 101
  integer, parameter :: ANY_SPACE_2 = 102
  !> @}

  !> @name What one call to the kernel is responsible for.
  !> @{
  integer, parameter :: CELL_COLUMN = 1
  !> @}

  !> One row of the metadata table: a description of a single kernel argument.
  type :: arg_type
    integer :: form         = -1  !< GH_FIELD, GH_OPERATOR, ...
    integer :: datatype     = -1  !< GH_REAL, ...
    integer :: access       = -1  !< GH_READ, GH_INC, ...
    integer :: function_space_to   = -1
    integer :: function_space_from = -1
  end type arg_type

  !> The base type every kernel extends. It carries no data: extending it is
  !> a *marker*, the thing that tells PSyclone "this derived type is kernel
  !> metadata, go and read it".
  type, abstract :: kernel_type
    private
  end type kernel_type

end module mini_argument_mod
