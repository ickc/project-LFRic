!> @brief The field and its proxy, in miniature.
!>
!> @details Two types for one thing, and the reason is an architectural rule
!>          rather than a technical one.
!>
!>          `field_type` is what the *algorithm layer* sees. Its data component
!>          is `private`, so algorithm code physically cannot index into the
!>          array: it can only pass whole fields to kernels. That is what stops
!>          science code from acquiring opinions about data layout, halos or
!>          decomposition.
!>
!>          `field_proxy_type` is what the *PSy layer* sees. Its data component
!>          is a `public, pointer`, aliasing the very same array. The PSy layer
!>          is generated code, it is allowed to know everything, and it is the
!>          only place a raw index appears.
!>
!>          `get_proxy` is therefore a deliberate hole in the encapsulation,
!>          punched in one named place. A C++ reader will recognise it as a
!>          `friend` accessor; note also that it hands out a modifiable pointer
!>          to the components of an `intent(in)` argument, which is legal
!>          Fortran outside a `pure` procedure and is very much the point.
module mini_field_mod

  use mini_constants_mod,      only : i_def, r_def
  use mini_function_space_mod, only : function_space_type

  implicit none

  private
  public :: field_type, field_proxy_type

  !> Algorithm-layer view: opaque.
  type :: field_type
    private
    real(r_def), allocatable :: data(:)
    type(function_space_type), pointer :: vspace => null()
    character(:), allocatable :: name
  contains
    procedure, public :: initialise => field_initialiser
    procedure, public :: get_proxy
    procedure, public :: get_name
  end type field_type

  !> PSy-layer view: an accessor whose components are public pointers.
  type :: field_proxy_type
    real(r_def), public, pointer :: data(:) => null()
    type(function_space_type), public, pointer :: vspace => null()
  end type field_proxy_type

contains

  !> @brief Allocate the field on a function space and zero it.
  !> @param[inout] self         The field
  !> @param[in]    vector_space The space the field lives on
  !> @param[in]    name         The field's name, for logging
  subroutine field_initialiser(self, vector_space, name)

    implicit none

    class(field_type),                  intent(inout) :: self
    type(function_space_type), pointer, intent(in)    :: vector_space
    character(*),                       intent(in)    :: name

    self%vspace => vector_space
    self%name   = name

    if (allocated(self%data)) deallocate( self%data )
    allocate( self%data(vector_space%get_undf()) )
    self%data(:) = 0.0_r_def

  end subroutine field_initialiser

  !> @brief Hand out the accessor the PSy layer needs.
  !> @param[in] self The field
  !> @return proxy An accessor aliasing this field's data
  function get_proxy(self) result(proxy)

    implicit none

    ! `target` is what makes the pointer assignments below legal: without it,
    ! `self` need not have an address a pointer can hold.
    class(field_type), target, intent(in) :: self
    type(field_proxy_type) :: proxy

    proxy%data   => self%data
    proxy%vspace => self%vspace

  end function get_proxy

  !> @brief The field's name.
  !> @param[in] self The field
  !> @return name The name given at initialisation
  function get_name(self) result(name)

    implicit none

    class(field_type), intent(in) :: self
    character(:), allocatable :: name

    name = self%name

  end function get_name

end module mini_field_mod
