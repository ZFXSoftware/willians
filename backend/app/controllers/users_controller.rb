class UsersController < ApplicationController
  def create
    user = User.create!(user_params)
    render json: user
  end

  private

  def user_params
    params.permit(:name, :email)
  end
end
