!> @brief The kind parameters, in miniature.
!>
!> @details LFRic's real `constants_mod` is 200 lines of the same idea: one
!>          named integer per role, so that a build-time switch can move the
!>          whole model between precisions without touching a declaration.
!>          `r_def` is the model's working precision, `r_solver` the (often
!>          lower) precision of the iterative solver, `i_def` the default
!>          integer.
module mini_constants_mod

  use, intrinsic :: iso_fortran_env, only : int32, real64

  implicit none

  private
  public :: i_def, r_def

  integer, parameter :: i_def = int32   !< Default integer kind
  integer, parameter :: r_def = real64  !< Default real kind

end module mini_constants_mod
