Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token
  resource :user_settings, only: %i[show edit update]
  resources :agents do
    member do
      get "oauth/login_start", to: "claude_oauth#login_start", as: :oauth_login_start
      post "oauth/login_finish", to: "claude_oauth#login_finish", as: :oauth_login_finish
      post "oauth/refresh", to: "claude_oauth#refresh", as: :oauth_refresh
    end
  end
  resources :projects do
    resources :tasks, shallow: true do
      member do
        get :branches
        patch :update_auto_push
        post :build_and_run_container
        post :stop_container
        post :restart_container
        delete :remove_container
      end
      resources :runs, only: %i[create]
    end
  end

  resources :tasks, only: %i[create]

  mount MissionControl::Jobs::Engine, at: "/jobs"

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  root "dashboard#index"
end
