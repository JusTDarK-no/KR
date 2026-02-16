from django.urls import path
from . import views

app_name = 'delservice_app'

urlpatterns = [
    # Основные страницы
    path('', views.dashboard, name='dashboard'),
    path('reports/', views.reports, name='reports'),
    path('reports/pdf/', views.generate_pdf_report, name='generate_pdf_report'),

    # Управление заказами
    path('orders/', views.order_list, name='order_list'),
    path('orders/<int:order_id>/', views.order_detail, name='order_detail'),
    path('orders/create/', views.order_create, name='order_create'),
    path('orders/<int:order_id>/edit/', views.order_update, name='order_update'),
    path('orders/<int:order_id>/delete/', views.order_delete, name='order_delete'),

    # Управление клиентами
    path('clients/', views.client_list, name='client_list'),
    path('clients/create/', views.client_create, name='client_create'),
    path('clients/<int:client_id>/edit/', views.client_update, name='client_update'),
    path('clients/<int:client_id>/delete/', views.client_delete, name='client_delete'),

    # Управление пользователями (сотрудниками)
    path('users/', views.user_list, name='user_list'),
    path('users/create/', views.user_create, name='user_create'),
    path('users/<int:user_id>/edit/', views.user_update, name='user_update'),
    path('users/<int:user_id>/delete/', views.user_delete, name='user_delete'),

    # Управление ролями
    path('roles/', views.role_list, name='role_list'),
    path('roles/create/', views.role_create, name='role_create'),
    path('roles/<int:role_id>/edit/', views.role_update, name='role_update'),
    path('roles/<int:role_id>/delete/', views.role_delete, name='role_delete'),

    # Управление товарами
    path('products/', views.product_list, name='product_list'),
    path('products/create/', views.product_create, name='product_create'),
    path('products/<int:product_id>/edit/', views.product_update, name='product_update'),
    path('products/<int:product_id>/delete/', views.product_delete, name='product_delete'),

    # Управление адресами
    path('addresses/', views.address_list, name='address_list'),
    path('addresses/create/', views.address_create, name='address_create'),
    path('addresses/<int:address_id>/edit/', views.address_update, name='address_update'),
    path('addresses/<int:address_id>/delete/', views.address_delete, name='address_delete'),

    # Управление статусами заказов
    path('order-statuses/', views.order_status_list, name='order_status_list'),
    path('order-statuses/create/', views.order_status_create, name='order_status_create'),
    path('order-statuses/<int:status_id>/edit/', views.order_status_update, name='order_status_update'),
    path('order-statuses/<int:status_id>/delete/', views.order_status_delete, name='order_status_delete'),

    # Управление способами оплаты
    path('payment-methods/', views.payment_method_list, name='payment_method_list'),
    path('payment-methods/create/', views.payment_method_create, name='payment_method_create'),
    path('payment-methods/<int:method_id>/edit/', views.payment_method_update, name='payment_method_update'),
    path('payment-methods/<int:method_id>/delete/', views.payment_method_delete, name='payment_method_delete'),

    # Управление заказами
    path('orders/', views.order_list, name='order_list'),
    path('orders/<int:order_id>/', views.order_detail, name='order_detail'),
    path('orders/create/', views.order_create, name='order_create'),
    path('orders/<int:order_id>/edit/', views.order_update, name='order_update'),
    path('orders/<int:order_id>/delete/', views.order_delete, name='order_delete'),
    path('orders/<int:order_id>/add-item/', views.order_item_create, name='order_add_item'),
    path('order-items/<int:item_id>/delete/', views.order_item_delete, name='order_item_delete'),

    path('logout/', views.logout_confirm, name='logout'),
]