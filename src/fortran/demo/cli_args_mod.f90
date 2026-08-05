!> @brief A small argument parser, in standard Fortran and nothing else.
!>
!> @details Every ingredient here is Fortran 2003 intrinsic: there is no C
!>          shim, no FFI, no library. The two intrinsics that matter are
!>          `command_argument_count()` and `get_command_argument()`, and the
!>          only awkward part is that the latter fills a *fixed-length*
!>          character buffer, so retrieving an argument of unknown length is a
!>          two-call dance: ask for the length, allocate, ask again.
!>
!>          LFRic's own `cli_mod` (`lfric_core/infrastructure/source/utilities/`)
!>          does exactly this, for exactly this reason.
module cli_args_mod

  use, intrinsic :: iso_fortran_env, only : error_unit

  implicit none

  private
  public :: argument, argument_count, has_flag, option_value, positional

contains

  !> @brief Number of command-line arguments, excluding the program name.
  !> @return count The argument count
  function argument_count() result(count)

    implicit none

    integer :: count

    count = command_argument_count()

  end function argument_count

  !> @brief Fetch argument `index` as a right-sized string.
  !> @param[in] index Which argument, 1-based; 0 is the program name
  !> @return arg The argument, allocated to exactly the length it needs
  function argument(index) result(arg)

    implicit none

    integer, intent(in) :: index
    character(:), allocatable :: arg

    ! A zero-length buffer: the call cannot write into it, but it still
    ! reports the length it would have needed. That is the whole trick.
    character(0) :: probe
    integer      :: length, status

    call get_command_argument( index, probe, length, status )
    allocate( character(length) :: arg )
    call get_command_argument( index, arg, length, status )

    if (status /= 0) then
      write( error_unit, '("cli: could not read argument ",I0)' ) index
      arg = ''
    end if

  end function argument

  !> @brief Is a bare switch such as `--verbose` present?
  !> @param[in] name The switch, including its leading dashes
  !> @return found Whether the switch appeared
  function has_flag(name) result(found)

    implicit none

    character(*), intent(in) :: name
    logical :: found

    integer :: i

    found = .false.
    do i = 1, argument_count()
      if (argument(i) == name) then
        found = .true.
        return
      end if
    end do

  end function has_flag

  !> @brief Value of an option given as `--key value` or `--key=value`.
  !> @param[in] name    The option, including its leading dashes
  !> @param[in] default Returned when the option is absent
  !> @return value The option's value
  function option_value(name, default) result(value)

    implicit none

    character(*), intent(in) :: name
    character(*), intent(in) :: default
    character(:), allocatable :: value

    character(:), allocatable :: arg
    integer :: i, n

    value = default
    n = argument_count()

    do i = 1, n
      arg = argument(i)
      if (arg == name) then
        if (i < n) value = argument(i + 1)
        return
      else if (len(arg) > len(name)) then
        if (arg(:len(name) + 1) == name // '=') then
          value = arg(len(name) + 2:)
          return
        end if
      end if
    end do

  end function option_value

  !> @brief The `n`-th argument that is not a switch and not a switch's value.
  !> @param[in] n Which positional argument is wanted, 1-based
  !> @return value The argument, or an empty string if there is no such one
  function positional(n) result(value)

    implicit none

    integer, intent(in) :: n
    character(:), allocatable :: value

    character(:), allocatable :: arg
    integer :: i, seen
    logical :: skip

    value = ''
    seen  = 0
    skip  = .false.

    do i = 1, argument_count()
      arg = argument(i)
      if (skip) then
        skip = .false.
        cycle
      end if
      if (len(arg) >= 1) then
        if (arg(1:1) == '-') then
          ! `--key value` consumes the next argument; `--key=value` does not.
          skip = index(arg, '=') == 0 .and. .not. is_known_flag(arg)
          cycle
        end if
      end if
      seen = seen + 1
      if (seen == n) then
        value = arg
        return
      end if
    end do

  end function positional

  !> @brief Switches that take no value, so `positional` does not eat the
  !!        argument that follows them.
  !> @param[in] name The switch to classify
  !> @return known Whether this is a value-less switch
  function is_known_flag(name) result(known)

    implicit none

    character(*), intent(in) :: name
    logical :: known

    known = name == '--verbose' .or. name == '-v' &
       .or. name == '--help'    .or. name == '-h'

  end function is_known_flag

end module cli_args_mod
