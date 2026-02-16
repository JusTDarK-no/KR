from django.contrib import admin
from django.utils.html import format_html
from .models import *


# Регистрация справочников
@admin.register(Role)
class RoleAdmin(admin.ModelAdmin):
    list_display = ('id', 'name', 'description')
    search_fields = ('name',)
    ordering = ('id',)


@admin.register(OrderStatus)
class OrderStatusAdmin(admin.ModelAdmin):
    list_display = ('id', 'code', 'name', 'sort_order')
    list_editable = ('sort_order',)
    ordering = ('sort_order',)


@admin.register(PaymentMethod)
class PaymentMethodAdmin(admin.ModelAdmin):
    list_display = ('id', 'code', 'name', 'fee_percent')
    list_editable = ('fee_percent',)
    search_fields = ('name',)


@admin.register(Product)
class ProductAdmin(admin.ModelAdmin):
    list_display = ('id', 'name', 'price', 'weight_kg', 'dimensions_cm')
    list_filter = ('price',)
    search_fields = ('name',)
    ordering = ('name',)


# Регистрация основных сущностей
@admin.register(Client)
class ClientAdmin(admin.ModelAdmin):
    list_display = ('id', 'full_name', 'email', 'phone', 'registration_date', 'status')
    list_filter = ('status', 'registration_date')
    search_fields = ('full_name', 'email', 'phone')
    readonly_fields = ('registration_date',)
    ordering = ('-registration_date',)


@admin.register(User)
class UserAdmin(admin.ModelAdmin):
    list_display = ('id', 'full_name', 'role', 'login', 'phone', 'status', 'hire_date')
    list_filter = ('role', 'status')
    search_fields = ('full_name', 'login', 'phone')
    readonly_fields = ('hire_date',)
    ordering = ('hire_date',)


@admin.register(Address)
class AddressAdmin(admin.ModelAdmin):
    list_display = ('id', 'street', 'house_number', 'apartment_number', 'floor', 'coordinates_link')
    search_fields = ('street', 'house_number')
    list_filter = ('street',)

    def coordinates_link(self, obj):
        if obj.latitude and obj.longitude:
            return format_html(
                '<a href="https://yandex.ru/maps/?ll={}%2C{}&z=16" target="_blank">Показать на карте</a>',
                obj.longitude, obj.latitude
            )
        return '-'

    coordinates_link.short_description = 'Координаты'


# Инлайн-таблица для отображения товаров в заказе
class OrderItemInline(admin.TabularInline):
    model = OrderItem
    extra = 1
    readonly_fields = ('price_at_order',)
    fields = ('product', 'quantity', 'price_at_order')


@admin.register(Order)
class OrderAdmin(admin.ModelAdmin):
    list_display = ('id', 'client', 'courier', 'status', 'delivery_cost', 'order_total',
                    'payment_method', 'created_at', 'delivered_at')
    list_filter = ('status', 'payment_method', 'created_at', 'courier')
    search_fields = ('client__full_name', 'client__phone')
    readonly_fields = ('created_at', 'order_total')
    date_hierarchy = 'created_at'
    inlines = [OrderItemInline]

    fieldsets = (
        ('Основная информация', {
            'fields': ('client', 'status', 'courier', 'comment')
        }),
        ('Адреса', {
            'fields': ('delivery_address', 'pickup_address')
        }),
        ('Финансы', {
            'fields': ('delivery_cost', 'order_total', 'payment_method')
        }),
        ('Временные метки', {
            'fields': ('created_at', 'confirmed_at', 'courier_assigned_at',
                       'dispatched_at', 'delivered_at'),
            'classes': ('collapse',)
        }),
    )

    def get_queryset(self, request):
        return super().get_queryset(request).select_related(
            'client', 'courier', 'status', 'payment_method'
        )


@admin.register(Review)
class ReviewAdmin(admin.ModelAdmin):
    list_display = ('id', 'order', 'rating', 'created_at', 'short_text')
    list_filter = ('rating', 'created_at')
    readonly_fields = ('order', 'created_at')

    def short_text(self, obj):
        return obj.text[:50] + '...' if obj.text and len(obj.text) > 50 else obj.text

    short_text.short_description = 'Отзыв'


@admin.register(Payment)
class PaymentAdmin(admin.ModelAdmin):
    list_display = ('id', 'order', 'payment_method', 'amount', 'status', 'transaction_number', 'paid_at')
    list_filter = ('status', 'payment_method', 'paid_at')
    search_fields = ('transaction_number',)
    readonly_fields = ('paid_at',)

    def get_queryset(self, request):
        return super().get_queryset(request).select_related('order', 'payment_method')