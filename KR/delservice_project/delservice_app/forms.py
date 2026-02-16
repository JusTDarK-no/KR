from django import forms
from django.contrib.auth.hashers import make_password
from .models import Client, Order, OrderItem, Address, Review, Payment, OrderStatus, Role, User, Product, PaymentMethod


class ClientForm(forms.ModelForm):
    """Форма для создания/редактирования клиента"""

    class Meta:
        model = Client
        fields = ['full_name', 'email', 'phone', 'status']
        widgets = {
            'full_name': forms.TextInput(attrs={'class': 'form-control'}),
            'email': forms.EmailInput(attrs={'class': 'form-control'}),
            'phone': forms.TextInput(attrs={'class': 'form-control', 'placeholder': '+7 (XXX) XXX-XX-XX'}),
            'status': forms.Select(attrs={'class': 'form-control'}),
        }


class AddressForm(forms.ModelForm):
    """Форма для создания/редактирования адреса"""

    class Meta:
        model = Address
        fields = ['street', 'house_number', 'apartment_number', 'entrance',
                  'floor', 'door_code', 'latitude', 'longitude']
        widgets = {
            'street': forms.TextInput(attrs={'class': 'form-control'}),
            'house_number': forms.TextInput(attrs={'class': 'form-control'}),
            'apartment_number': forms.TextInput(attrs={'class': 'form-control'}),
            'entrance': forms.TextInput(attrs={'class': 'form-control'}),
            'floor': forms.NumberInput(attrs={'class': 'form-control'}),
            'door_code': forms.TextInput(attrs={'class': 'form-control'}),
            'latitude': forms.NumberInput(attrs={'class': 'form-control', 'step': '0.0000001'}),
            'longitude': forms.NumberInput(attrs={'class': 'form-control', 'step': '0.0000001'}),
        }


class OrderForm(forms.ModelForm):
    """Форма для создания/редактирования заказа"""

    class Meta:
        model = Order
        fields = ['client', 'delivery_address', 'pickup_address', 'courier',
                  'status', 'delivery_cost', 'payment_method', 'comment']
        widgets = {
            'client': forms.Select(attrs={'class': 'form-control'}),
            'delivery_address': forms.Select(attrs={'class': 'form-control'}),
            'pickup_address': forms.Select(attrs={'class': 'form-control'}),
            'courier': forms.Select(attrs={'class': 'form-control'}),
            'status': forms.Select(attrs={'class': 'form-control'}),
            'delivery_cost': forms.NumberInput(attrs={'class': 'form-control'}),
            'payment_method': forms.Select(attrs={'class': 'form-control'}),
            'comment': forms.Textarea(attrs={'class': 'form-control', 'rows': 3}),
        }


class OrderSearchForm(forms.Form):
    """Форма для поиска и фильтрации заказов"""

    client_name = forms.CharField(
        required=False,
        label='Клиент',
        widget=forms.TextInput(attrs={'class': 'form-control', 'placeholder': 'Поиск по ФИО'})
    )

    status = forms.ChoiceField(
        required=False,
        label='Статус',
        widget=forms.Select(attrs={'class': 'form-control'})
    )

    date_from = forms.DateField(
        required=False,
        label='Дата от',
        widget=forms.DateInput(attrs={'class': 'form-control', 'type': 'date'})
    )

    date_to = forms.DateField(
        required=False,
        label='Дата до',
        widget=forms.DateInput(attrs={'class': 'form-control', 'type': 'date'})
    )

    courier = forms.IntegerField(
        required=False,
        label='Курьер ID',
        widget=forms.NumberInput(attrs={'class': 'form-control', 'placeholder': 'ID курьера'})
    )

    def __init__(self, *args, **kwargs):
        """Динамическая загрузка статусов при создании формы"""
        super().__init__(*args, **kwargs)
        # Загружаем статусы из базы данных при инициализации формы
        from .models import OrderStatus
        self.fields['status'].choices = [('', 'Все')] + [
            (s.code, s.name) for s in OrderStatus.objects.all()
        ]


class RoleForm(forms.ModelForm):
    """Форма для управления ролями"""

    class Meta:
        model = Role
        fields = ['name', 'description']
        widgets = {
            'name': forms.TextInput(attrs={'class': 'form-control'}),
            'description': forms.Textarea(attrs={'class': 'form-control', 'rows': 3}),
        }


class UserForm(forms.ModelForm):
    """Форма для управления пользователями (сотрудниками)"""
    password = forms.CharField(
        required=False,
        widget=forms.PasswordInput(attrs={'class': 'form-control'}),
        label='Пароль (оставьте пустым для сохранения текущего)'
    )

    class Meta:
        model = User
        fields = ['role', 'login', 'full_name', 'phone', 'status', 'hire_date']
        widgets = {
            'role': forms.Select(attrs={'class': 'form-control'}),
            'login': forms.TextInput(attrs={'class': 'form-control'}),
            'full_name': forms.TextInput(attrs={'class': 'form-control'}),
            'phone': forms.TextInput(attrs={'class': 'form-control'}),
            'status': forms.Select(attrs={'class': 'form-control'}),
            'hire_date': forms.DateInput(attrs={'class': 'form-control', 'type': 'date'}),
        }

    def save(self, commit=True):
        user = super().save(commit=False)
        password = self.cleaned_data.get('password')
        if password:
            user.password_hash = make_password(password)
        if commit:
            user.save()
        return user


class ProductForm(forms.ModelForm):
    """Форма для управления товарами"""

    class Meta:
        model = Product
        fields = ['name', 'description', 'price', 'weight_kg', 'dimensions_cm']
        widgets = {
            'name': forms.TextInput(attrs={'class': 'form-control'}),
            'description': forms.Textarea(attrs={'class': 'form-control', 'rows': 3}),
            'price': forms.NumberInput(attrs={'class': 'form-control'}),
            'weight_kg': forms.NumberInput(attrs={'class': 'form-control', 'step': '0.01'}),
            'dimensions_cm': forms.TextInput(attrs={'class': 'form-control', 'placeholder': 'Д×Ш×В'}),
        }


class PaymentMethodForm(forms.ModelForm):
    """Форма для управления способами оплаты"""

    class Meta:
        model = PaymentMethod
        fields = ['code', 'name', 'fee_percent']
        widgets = {
            'code': forms.TextInput(attrs={'class': 'form-control'}),
            'name': forms.TextInput(attrs={'class': 'form-control'}),
            'fee_percent': forms.NumberInput(attrs={'class': 'form-control', 'step': '0.01'}),
        }


class OrderStatusForm(forms.ModelForm):
    """Форма для управления статусами заказов"""

    class Meta:
        model = OrderStatus
        fields = ['code', 'name', 'sort_order']
        widgets = {
            'code': forms.TextInput(attrs={'class': 'form-control'}),
            'name': forms.TextInput(attrs={'class': 'form-control'}),
            'sort_order': forms.NumberInput(attrs={'class': 'form-control'}),
        }